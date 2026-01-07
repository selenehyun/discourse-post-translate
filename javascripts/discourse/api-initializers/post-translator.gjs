import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

// State management for tracking translations per post ID
const translationState = new Map();
// Track which posts have buttons to avoid duplicates
const buttonsAdded = new Set();

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
async function translatePost(postId, targetLang) {
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
async function handleTranslate(postId, button) {
  console.log("[Post Translator] handleTranslate called for post:", postId);

  const cookedElement = document.querySelector(
    `article[data-post-id="${postId}"] .cooked`
  );

  if (!cookedElement) {
    console.error("[Post Translator] Could not find cooked element for post", postId);
    return;
  }

  let state = translationState.get(postId);
  if (!state) {
    state = {
      isTranslated: false,
      originalHTML: cookedElement.innerHTML,
      translatedHTML: null,
    };
    translationState.set(postId, state);
  }

  const labelSpan = button.querySelector(".d-button-label");

  // Toggle back to original
  if (state.isTranslated) {
    cookedElement.innerHTML = state.originalHTML;
    state.isTranslated = false;
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.translate_button"));
    }
    return;
  }

  // Use cached translation if available
  if (state.translatedHTML) {
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.show_original_button"));
    }
    return;
  }

  // Show loading state
  button.disabled = true;
  if (labelSpan) {
    labelSpan.textContent = i18n(themePrefix("post_translator.translating"));
  }

  // Call API
  const result = await translatePost(postId, getTargetLanguage());

  button.disabled = false;

  if (result.success) {
    state.translatedHTML = result.translatedText;
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.show_original_button"));
    }
  } else {
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.translate_button"));
    }
  }
}

/**
 * Add translate button to a single post
 */
function addButtonToPost(post) {
  const articleElement = post.querySelector("article[data-post-id]");
  if (!articleElement) return;

  const postId = articleElement.dataset.postId;
  if (!postId) return;

  const actionsContainer = post.querySelector(".post-controls .actions");
  if (!actionsContainer) return;

  // Check if button already exists in DOM
  if (actionsContainer.querySelector(".post-translate-btn")) {
    return;
  }

  // Get current state for label
  const state = translationState.get(parseInt(postId));
  const isTranslated = state?.isTranslated || false;

  const label = isTranslated
    ? i18n(themePrefix("post_translator.show_original_button"))
    : i18n(themePrefix("post_translator.translate_button"));

  // Create button
  const button = document.createElement("button");
  button.className = "btn btn-icon-text post-translate-btn btn-flat";
  button.type = "button";
  button.title = label;
  button.innerHTML = `<svg class="fa d-icon d-icon-globe svg-icon svg-string" xmlns="http://www.w3.org/2000/svg"><use href="#globe"></use></svg><span class="d-button-label">${label}</span>`;

  button.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    handleTranslate(parseInt(postId), button);
  });

  actionsContainer.appendChild(button);
}

/**
 * Scan all posts and add buttons
 */
function scanAndAddButtons() {
  const posts = document.querySelectorAll(".topic-post");
  posts.forEach(addButtonToPost);
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

  let observer = null;
  let scanTimeout = null;

  const debouncedScan = () => {
    if (scanTimeout) {
      clearTimeout(scanTimeout);
    }
    scanTimeout = setTimeout(scanAndAddButtons, 100);
  };

  // Setup MutationObserver
  const setupObserver = () => {
    if (observer) {
      observer.disconnect();
    }

    const container = document.querySelector("#main-outlet, .topic-area, body");
    if (!container) return;

    observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.addedNodes.length > 0) {
          debouncedScan();
          break;
        }
      }
    });

    observer.observe(container, {
      childList: true,
      subtree: true,
    });

    // Initial scan
    debouncedScan();
  };

  // Setup on page change
  api.onPageChange(() => {
    // Clear button tracking for fresh page
    buttonsAdded.clear();
    setTimeout(setupObserver, 300);
  });

  // Initial setup
  setTimeout(setupObserver, 500);
});
