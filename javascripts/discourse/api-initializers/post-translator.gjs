import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

// State management for tracking translations per post ID
const translationState = new Map();

/**
 * Get the target language from browser settings
 */
function getTargetLanguage() {
  const browserLang = navigator.language || navigator.userLanguage;
  return browserLang.split("-")[0];
}

/**
 * Call the translation API
 */
async function translatePost(postId, targetLang, apiUrl, timeout, debugMode) {
  console.log("[Post Translator] Calling API (MOCKED)");
  console.log("[Post Translator] Post ID:", postId);
  console.log("[Post Translator] Target language:", targetLang);

  // === MOCK RESPONSE FOR TESTING ===
  await new Promise((resolve) => setTimeout(resolve, 500));

  return {
    success: true,
    translatedText: `<p><strong>[번역됨 - Post ID: ${postId}]</strong></p><p>이것은 테스트용 번역 결과입니다. 원본 내용이 이 텍스트로 대체되어야 합니다.</p><p>Target language: ${targetLang}</p>`,
    detectedLanguage: "en",
  };
  // === END MOCK ===
}

/**
 * Handle translation toggle
 */
async function handleTranslate(postId, settings) {
  console.log("[Post Translator] handleTranslate called for post:", postId);

  // Find the cooked element for this post
  const cookedElement = document.querySelector(
    `article[data-post-id="${postId}"] .cooked`
  );

  if (!cookedElement) {
    console.error("[Post Translator] Could not find cooked element for post", postId);
    return;
  }

  // Find the button
  const button = document.querySelector(`.post-translate-btn[data-post-id="${postId}"]`);
  if (!button) {
    console.error("[Post Translator] Could not find button for post", postId);
    return;
  }

  // Get or initialize state
  let state = translationState.get(postId);
  if (!state) {
    state = {
      isTranslated: false,
      originalHTML: cookedElement.innerHTML,
      translatedHTML: null,
    };
    translationState.set(postId, state);
  }

  // Toggle back to original
  if (state.isTranslated) {
    cookedElement.innerHTML = state.originalHTML;
    state.isTranslated = false;
    button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.translate_button"));
    button.title = "Translate";
    return;
  }

  // Use cached translation if available
  if (state.translatedHTML) {
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.show_original_button"));
    button.title = "Show original";
    return;
  }

  // Show loading state
  button.disabled = true;
  const originalLabel = button.querySelector(".d-button-label").textContent;
  button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.translating"));

  // Call API
  const result = await translatePost(
    postId,
    getTargetLanguage(),
    settings.translation_api_url,
    settings.translation_api_timeout || 10000,
    settings.debug_mode
  );

  button.disabled = false;

  if (result.success) {
    state.translatedHTML = result.translatedText;
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.show_original_button"));
    button.title = "Show original";
  } else {
    button.querySelector(".d-button-label").textContent = i18n(themePrefix(`post_translator.${result.errorKey}`));
    button.classList.add("btn-danger");
    setTimeout(() => {
      button.querySelector(".d-button-label").textContent = originalLabel;
      button.classList.remove("btn-danger");
    }, 3000);
  }
}

export default apiInitializer("1.0.0", (api) => {
  // Check if feature is enabled
  if (!settings.show_translation_button) {
    return;
  }

  // Only show for logged-in users
  const currentUser = api.getCurrentUser();
  if (!currentUser) {
    console.log("[Post Translator] User not logged in, skipping");
    return;
  }

  console.log("[Post Translator] Initializing for user:", currentUser.username);

  /**
   * Add translate button to a post if not already present
   */
  function addButtonToPost(post) {
    const articleElement = post.querySelector("article[data-post-id]");
    const postId = articleElement ? articleElement.dataset.postId : null;

    if (!postId) return;

    // Skip if button already exists
    if (post.querySelector(".post-translate-btn")) {
      return;
    }

    // Find the actions container
    const actionsContainer = post.querySelector(".post-controls .actions");
    if (!actionsContainer) return;

    // Check current translation state
    const state = translationState.get(parseInt(postId));
    const isTranslated = state?.isTranslated || false;

    // Create button
    const button = document.createElement("button");
    button.className = "btn btn-icon-text post-translate-btn btn-flat";
    button.type = "button";
    button.title = isTranslated ? "Show original" : "Translate";
    button.dataset.postId = postId;

    const label = isTranslated
      ? i18n(themePrefix("post_translator.show_original_button"))
      : i18n(themePrefix("post_translator.translate_button"));

    button.innerHTML = `<svg class="fa d-icon d-icon-globe svg-icon svg-string" xmlns="http://www.w3.org/2000/svg"><use href="#globe"></use></svg><span class="d-button-label">${label}</span>`;

    button.addEventListener("click", () => handleTranslate(parseInt(postId), settings));

    actionsContainer.appendChild(button);
  }

  /**
   * Scan and add buttons to all visible posts
   */
  function addButtonsToAllPosts() {
    const posts = document.querySelectorAll(".topic-post");
    posts.forEach(addButtonToPost);
  }

  // Initial scan on page change
  api.onPageChange(() => {
    setTimeout(addButtonsToAllPosts, 300);
  });

  // Use MutationObserver to handle re-renders from virtual scrolling
  const observer = new MutationObserver((mutations) => {
    let shouldScan = false;

    for (const mutation of mutations) {
      // Check if nodes were added
      if (mutation.addedNodes.length > 0) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType === Node.ELEMENT_NODE) {
            // Check if it's a post or contains posts
            if (node.classList?.contains("topic-post") || node.querySelector?.(".topic-post")) {
              shouldScan = true;
              break;
            }
          }
        }
      }
      if (shouldScan) break;
    }

    if (shouldScan) {
      // Debounce the scan
      clearTimeout(observer.scanTimeout);
      observer.scanTimeout = setTimeout(addButtonsToAllPosts, 100);
    }
  });

  // Start observing the topic stream
  const startObserving = () => {
    const topicStream = document.querySelector(".topic-stream, .post-stream, #topic");
    if (topicStream) {
      observer.observe(topicStream, {
        childList: true,
        subtree: true,
      });
      console.log("[Post Translator] MutationObserver started");
    }
  };

  // Start observer on page change
  api.onPageChange(() => {
    setTimeout(startObserving, 500);
  });
});
