import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

// State management for tracking translations per element
const translationState = new WeakMap();

/**
 * Get the target language from browser settings
 * Returns 2-letter language code (e.g., "ko", "en", "ja")
 */
function getTargetLanguage() {
  const browserLang = navigator.language || navigator.userLanguage;
  return browserLang.split("-")[0];
}

/**
 * Create the translation button element
 */
function createTranslateButton(isTranslated) {
  const button = document.createElement("button");
  button.className = "btn btn-icon-text post-translate-btn btn-flat";
  button.type = "button";
  button.title = isTranslated ? "Show original" : "Translate";

  const label = isTranslated
    ? i18n(themePrefix("post_translator.show_original_button"))
    : i18n(themePrefix("post_translator.translate_button"));

  button.innerHTML = `<svg class="fa d-icon d-icon-globe svg-icon svg-string" xmlns="http://www.w3.org/2000/svg"><use href="#globe"></use></svg><span class="d-button-label">${label}</span>`;

  return button;
}

/**
 * Update button label based on state
 */
function updateButtonLabel(button, isTranslated) {
  const label = button.querySelector(".d-button-label");
  if (label) {
    label.textContent = isTranslated
      ? i18n(themePrefix("post_translator.show_original_button"))
      : i18n(themePrefix("post_translator.translate_button"));
  }
  button.title = isTranslated ? "Show original" : "Translate";
}

/**
 * Call the translation API
 */
async function translatePost(postId, targetLang, apiUrl, timeout, debugMode) {
  console.log("[Post Translator] Calling API (MOCKED)");
  console.log("[Post Translator] Post ID:", postId);
  console.log("[Post Translator] Target language:", targetLang);

  // === MOCK RESPONSE FOR TESTING ===
  // Simulate network delay
  await new Promise((resolve) => setTimeout(resolve, 500));

  // Return mocked translation
  return {
    success: true,
    translatedText: `<p><strong>[번역됨 - Post ID: ${postId}]</strong></p><p>이것은 테스트용 번역 결과입니다. 원본 내용이 이 텍스트로 대체되어야 합니다.</p><p>Target language: ${targetLang}</p>`,
    detectedLanguage: "en",
  };
  // === END MOCK ===

  /*
  // === ORIGINAL API CALL (commented out for testing) ===
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeout);

  try {
    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        post_id: postId,
        target_language: targetLang,
      }),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const data = await response.json();

    if (!data.success) {
      return { success: false, errorKey: "error_generic" };
    }

    return {
      success: true,
      translatedText: data.translated_text,
      detectedLanguage: data.detected_language,
    };
  } catch (error) {
    clearTimeout(timeoutId);

    if (debugMode) {
      console.error("[Post Translator] API Error:", error);
    }

    if (error.name === "AbortError") {
      return { success: false, errorKey: "error_timeout" };
    }

    if (error instanceof TypeError) {
      return { success: false, errorKey: "error_network" };
    }

    return { success: false, errorKey: "error_generic" };
  }
  // === END ORIGINAL API CALL ===
  */
}

/**
 * Handle translation toggle click
 */
async function handleTranslateClick(event, cookedElement, postId, settings, originalHTML) {
  console.log("[Post Translator] Button clicked, postId:", postId);

  const button = event.currentTarget;

  // Get or initialize state for this element
  let state = translationState.get(cookedElement);
  if (!state) {
    state = {
      isTranslated: false,
      originalHTML: originalHTML,
      translatedHTML: null,
    };
    translationState.set(cookedElement, state);
  }

  // Toggle back to original
  if (state.isTranslated) {
    cookedElement.innerHTML = state.originalHTML;
    state.isTranslated = false;
    updateButtonLabel(button, false);
    return;
  }

  // If we already have a translation, use cached version
  if (state.translatedHTML) {
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    updateButtonLabel(button, true);
    return;
  }

  // Show loading state
  button.disabled = true;
  const originalButtonText = button.innerHTML;
  button.innerHTML = `<span class="d-button-label">${i18n(themePrefix("post_translator.translating"))}</span>`;

  // Get target language from browser
  const targetLang = getTargetLanguage();

  // Call API
  const result = await translatePost(
    postId,
    targetLang,
    settings.translation_api_url,
    settings.translation_api_timeout || 10000,
    settings.debug_mode
  );

  // Restore button state
  button.disabled = false;

  if (result.success) {
    state.translatedHTML = result.translatedText;
    cookedElement.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    updateButtonLabel(button, true);
  } else {
    // Show error briefly in button, then restore
    button.innerHTML = `<span class="d-button-label">${i18n(themePrefix(`post_translator.${result.errorKey}`))}</span>`;
    button.classList.add("btn-danger");
    setTimeout(() => {
      button.innerHTML = originalButtonText;
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
    if (settings.debug_mode) {
      console.log(
        "[Post Translator] User not logged in, skipping initialization"
      );
    }
    return;
  }

  if (settings.debug_mode) {
    console.log(
      "[Post Translator] Initializing for user:",
      currentUser.username
    );
  }

  // Decorate all cooked elements (post content)
  api.decorateCookedElement(
    (element, helper) => {
      // Skip if no helper (preview mode, etc.)
      if (!helper) {
        return;
      }

      // Get post model to access post_id
      const post = helper.getModel();
      if (!post || !post.id) {
        return;
      }

      // Find the post-controls .actions element
      const article = element.closest("article.boxed, .topic-post");
      console.log("[Post Translator] Article found:", article);
      if (!article) {
        console.log("[Post Translator] No article found for post", post.id);
        return;
      }

      const actionsContainer = article.querySelector(".post-controls .actions");
      console.log("[Post Translator] Actions container found:", actionsContainer);
      if (!actionsContainer) {
        console.log("[Post Translator] No .actions container found for post", post.id);
        return;
      }

      // Skip if button already added
      if (actionsContainer.querySelector(".post-translate-btn")) {
        console.log("[Post Translator] Button already exists for post", post.id);
        return;
      }

      // Store original content
      const originalHTML = element.innerHTML;

      // Create translate button
      const button = createTranslateButton(false);
      button.addEventListener("click", (event) =>
        handleTranslateClick(event, element, post.id, settings, originalHTML)
      );

      // Append button to .actions container
      actionsContainer.appendChild(button);
      console.log("[Post Translator] Button added for post", post.id);
    },
    {
      id: "post-translator",
      onlyStream: true, // Only apply to posts in the stream, not previews
    }
  );
});
