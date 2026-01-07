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
    `[data-post-id="${postId}"] .cooked, #post_${postId} .cooked`
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

  // Use onPageChange to add buttons after page renders
  api.onPageChange((url, title) => {
    console.log("[Post Translator] Page changed:", url);

    // Wait for DOM to be ready
    setTimeout(() => {
      // Find all posts that don't have translate button yet
      const posts = document.querySelectorAll(".topic-post");
      console.log("[Post Translator] Found posts:", posts.length);

      posts.forEach((post) => {
        const postId = post.dataset.postId;
        if (!postId) return;

        // Skip if button already exists
        if (post.querySelector(".post-translate-btn")) {
          return;
        }

        // Find the actions container
        const actionsContainer = post.querySelector(".post-controls .actions");
        if (!actionsContainer) {
          console.log("[Post Translator] No actions container for post", postId);
          return;
        }

        // Create button
        const button = document.createElement("button");
        button.className = "btn btn-icon-text post-translate-btn btn-flat";
        button.type = "button";
        button.title = "Translate";
        button.dataset.postId = postId;
        button.innerHTML = `<svg class="fa d-icon d-icon-globe svg-icon svg-string" xmlns="http://www.w3.org/2000/svg"><use href="#globe"></use></svg><span class="d-button-label">${i18n(themePrefix("post_translator.translate_button"))}</span>`;

        button.addEventListener("click", () => handleTranslate(parseInt(postId), settings));

        actionsContainer.appendChild(button);
        console.log("[Post Translator] Button added for post", postId);
      });
    }, 500);
  });
});
