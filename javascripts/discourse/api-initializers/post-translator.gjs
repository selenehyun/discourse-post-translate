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
async function handleTranslate(postId) {
  console.log("[Post Translator] handleTranslate called for post:", postId);

  // Find the cooked element
  const cookedElement = document.querySelector(
    `article[data-post-id="${postId}"] .cooked`
  );

  if (!cookedElement) {
    console.error("[Post Translator] Could not find cooked element for post", postId);
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

  // Find the button to update its state
  const button = document.querySelector(`.post-translate-btn[data-post-id="${postId}"]`);

  // Toggle back to original
  if (state.isTranslated) {
    cookedElement.innerHTML = state.originalHTML;
    state.isTranslated = false;
    if (button) {
      button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.translate_button"));
    }
    return;
  }

  // Use cached translation if available
  if (state.translatedHTML) {
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    if (button) {
      button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.show_original_button"));
    }
    return;
  }

  // Show loading state
  if (button) {
    button.disabled = true;
    button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.translating"));
  }

  // Call API
  const result = await translatePost(postId, getTargetLanguage());

  if (button) {
    button.disabled = false;
  }

  if (result.success) {
    state.translatedHTML = result.translatedText;
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    if (button) {
      button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.show_original_button"));
    }
  } else {
    console.error("[Post Translator] Translation failed");
    if (button) {
      button.querySelector(".d-button-label").textContent = i18n(themePrefix("post_translator.translate_button"));
    }
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

  // Use the new value transformer API for post menu buttons
  // value is a DAG (Directed Acyclic Graph) object
  api.registerValueTransformer("post-menu-buttons", ({ value, context }) => {
    const postId = context?.post?.id;
    if (!postId) {
      return value;
    }

    const state = translationState.get(postId);
    const isTranslated = state?.isTranslated || false;

    // Add button using DAG .add() method
    value.add("translate", {
      icon: "globe",
      className: "post-translate-btn",
      title: isTranslated
        ? themePrefix("post_translator.show_original_button")
        : themePrefix("post_translator.translate_button"),
      label: isTranslated
        ? themePrefix("post_translator.show_original_button")
        : themePrefix("post_translator.translate_button"),
      action: () => handleTranslate(postId),
    });

    return value;
  });
});
