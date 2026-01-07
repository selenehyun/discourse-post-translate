import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import { h } from "virtual-dom";

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

  // Custom action for translation
  api.attachWidgetAction("post", "translatePost", function () {
    const postId = this.model.id;
    console.log("[Post Translator] translatePost action for:", postId);

    const cookedElement = document.querySelector(
      `article[data-post-id="${postId}"] .cooked`
    );

    if (!cookedElement) {
      console.error("[Post Translator] Could not find cooked element");
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

    if (state.isTranslated) {
      cookedElement.innerHTML = state.originalHTML;
      state.isTranslated = false;
      this.scheduleRerender();
      return;
    }

    if (state.translatedHTML) {
      cookedElement.innerHTML = state.translatedHTML;
      state.isTranslated = true;
      this.scheduleRerender();
      return;
    }

    // Fetch translation
    translatePost(postId, getTargetLanguage()).then((result) => {
      if (result.success) {
        state.translatedHTML = result.translatedText;
        cookedElement.innerHTML = state.translatedHTML;
        state.isTranslated = true;
        this.scheduleRerender();
      }
    });
  });

  // Add button to post menu using decorateWidget
  api.decorateWidget("post-menu:before-extra-controls", (helper) => {
    const postId = helper.attrs.id;
    const state = translationState.get(postId);
    const isTranslated = state?.isTranslated || false;

    const label = isTranslated
      ? i18n(themePrefix("post_translator.show_original_button"))
      : i18n(themePrefix("post_translator.translate_button"));

    return helper.attach("button", {
      action: "translatePost",
      icon: "globe",
      label: label,
      title: label,
      className: "post-translate-btn btn-flat",
    });
  });
});
