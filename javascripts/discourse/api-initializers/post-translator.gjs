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
  button.className = "btn btn-default btn-small post-translate-btn";
  button.type = "button";

  const label = isTranslated
    ? i18n("post_translator.show_original_button")
    : i18n("post_translator.translate_button");

  button.innerHTML = `<span class="d-button-label">${label}</span>`;

  return button;
}

/**
 * Create loading indicator
 */
function createLoadingIndicator() {
  const loading = document.createElement("div");
  loading.className = "post-translate-loading";
  loading.innerHTML = `
    <span class="spinner small"></span>
    <span class="loading-text">${i18n("post_translator.translating")}</span>
  `;
  return loading;
}

/**
 * Show error message
 */
function showError(container, errorKey) {
  const existingError = container.querySelector(".post-translate-error");
  if (existingError) {
    existingError.remove();
  }

  const error = document.createElement("div");
  error.className = "post-translate-error";
  error.textContent = i18n(`post_translator.${errorKey}`);

  container.appendChild(error);

  // Auto-remove error after 5 seconds
  setTimeout(() => {
    if (error.parentNode) {
      error.remove();
    }
  }, 5000);
}

/**
 * Update button label based on state
 */
function updateButtonLabel(button, isTranslated) {
  const label = button.querySelector(".d-button-label");
  if (label) {
    label.textContent = isTranslated
      ? i18n("post_translator.show_original_button")
      : i18n("post_translator.translate_button");
  }
}

/**
 * Call the translation API
 */
async function translatePost(postId, targetLang, apiUrl, timeout, debugMode) {
  if (debugMode) {
    console.log("[Post Translator] Calling API:", apiUrl);
    console.log("[Post Translator] Post ID:", postId);
    console.log("[Post Translator] Target language:", targetLang);
  }

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
}

/**
 * Handle translation toggle click
 */
async function handleTranslateClick(event, element, postId, settings) {
  const button = event.currentTarget;
  const container = button.closest(".post-translate-container");

  // Get or initialize state for this element
  let state = translationState.get(element);
  if (!state) {
    state = {
      isTranslated: false,
      originalHTML: null,
      translatedHTML: null,
    };
    translationState.set(element, state);
  }

  // Find the cooked content
  const cookedContent = element.querySelector(".cooked");
  if (!cookedContent) {
    if (settings.debug_mode) {
      console.error("[Post Translator] Could not find .cooked element");
    }
    return;
  }

  // Toggle back to original
  if (state.isTranslated) {
    cookedContent.innerHTML = state.originalHTML;
    state.isTranslated = false;
    updateButtonLabel(button, false);
    return;
  }

  // Store original content
  if (!state.originalHTML) {
    state.originalHTML = cookedContent.innerHTML;
  }

  // If we already have a translation, use cached version
  if (state.translatedHTML) {
    cookedContent.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    updateButtonLabel(button, true);
    return;
  }

  // Show loading state
  button.disabled = true;
  const loadingIndicator = createLoadingIndicator();
  container.appendChild(loadingIndicator);

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

  // Remove loading indicator
  loadingIndicator.remove();
  button.disabled = false;

  if (result.success) {
    state.translatedHTML = result.translatedText;
    cookedContent.innerHTML = state.translatedHTML;
    state.isTranslated = true;
    updateButtonLabel(button, true);
  } else {
    showError(container, result.errorKey);
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

      // Skip if button already added
      if (element.querySelector(".post-translate-container")) {
        return;
      }

      // Create container for button and status
      const container = document.createElement("div");
      container.className = "post-translate-container";

      // Create and add button
      const button = createTranslateButton(false);
      button.addEventListener("click", (event) =>
        handleTranslateClick(event, element, post.id, settings)
      );

      container.appendChild(button);

      // Append to the end of the element
      element.appendChild(container);
    },
    {
      id: "post-translator",
      onlyStream: true, // Only apply to posts in the stream, not previews
    }
  );
});
