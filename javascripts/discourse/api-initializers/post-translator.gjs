import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

// State management for tracking translations per post ID
const translationState = new Map();
// Track which posts have buttons to avoid duplicates
const buttonsAdded = new Set();

/**
 * Debug logging helper - only logs when debug_mode is enabled
 */
function debugLog(...args) {
  if (settings.debug_mode) {
    console.log("[Post Translator]", ...args);
  }
}

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
  debugLog("Calling API for post:", postId, "target:", targetLang);

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), settings.translation_api_timeout);

  try {
    const response = await fetch(settings.translation_api_url, {
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
      debugLog("API error:", response.status, response.statusText);
      return {
        success: false,
        error: i18n(themePrefix("post_translator.error_generic")),
      };
    }

    const data = await response.json();
    debugLog("API response:", data);

    if (data.success) {
      return {
        success: true,
        translatedText: data.translated_text,
        detectedLanguage: data.detected_language,
      };
    } else {
      return {
        success: false,
        error: data.error?.message || i18n(themePrefix("post_translator.error_generic")),
      };
    }
  } catch (error) {
    clearTimeout(timeoutId);

    if (error.name === "AbortError") {
      debugLog("API timeout");
      return {
        success: false,
        error: i18n(themePrefix("post_translator.error_timeout")),
      };
    }

    debugLog("Network error:", error);
    return {
      success: false,
      error: i18n(themePrefix("post_translator.error_network")),
    };
  }
}

/**
 * Get or create translation container for a post
 */
function getOrCreateTranslationContainer(postId) {
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  if (!article) return null;

  const cookedElement = article.querySelector(".cooked");
  if (!cookedElement) return null;

  // Check if translation container already exists
  let container = article.querySelector(".post-translator-content");
  if (!container) {
    // Create container as sibling of cooked
    container = document.createElement("div");
    container.className = "post-translator-content cooked";
    container.style.display = "none";
    cookedElement.parentNode.insertBefore(container, cookedElement.nextSibling);
  }

  return { cookedElement, container };
}

/**
 * Handle translation toggle
 */
async function handleTranslate(postId, button) {
  debugLog("handleTranslate called for post:", postId);

  const elements = getOrCreateTranslationContainer(postId);
  if (!elements) {
    debugLog("Could not find elements for post", postId);
    return;
  }

  const { cookedElement, container } = elements;

  let state = translationState.get(postId);
  if (!state) {
    state = {
      isTranslated: false,
      translatedHTML: null,
    };
    translationState.set(postId, state);
  }

  const labelSpan = button.querySelector(".d-button-label");

  // Toggle back to original
  if (state.isTranslated) {
    cookedElement.style.display = "";
    container.style.display = "none";
    state.isTranslated = false;
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.translate_button"));
    }
    return;
  }

  // Use cached translation if available
  if (state.translatedHTML) {
    container.innerHTML = state.translatedHTML;
    cookedElement.style.display = "none";
    container.style.display = "";
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
    container.innerHTML = state.translatedHTML;
    cookedElement.style.display = "none";
    container.style.display = "";
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
 * Restore translation view if post was showing translation
 */
function restoreTranslationView(postId) {
  const state = translationState.get(postId);
  if (!state?.isTranslated || !state?.translatedHTML) return;

  const elements = getOrCreateTranslationContainer(postId);
  if (!elements) return;

  const { cookedElement, container } = elements;
  container.innerHTML = state.translatedHTML;
  cookedElement.style.display = "none";
  container.style.display = "";
}

/**
 * Add translate button to a single post
 */
function addButtonToPost(post) {
  const articleElement = post.querySelector("article[data-post-id]");
  if (!articleElement) return;

  const postId = articleElement.dataset.postId;
  if (!postId) return;

  const numericPostId = parseInt(postId);
  const actionsContainer = post.querySelector(".post-controls .actions");
  if (!actionsContainer) return;

  // Check if button already exists in DOM
  if (actionsContainer.querySelector(".post-translate-btn")) {
    // Button exists but need to check if translation view needs restoration
    restoreTranslationView(numericPostId);
    return;
  }

  // Get current state for label
  const state = translationState.get(numericPostId);
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
    handleTranslate(numericPostId, button);
  });

  actionsContainer.appendChild(button);

  // Restore translation view if this post was showing translation before re-render
  restoreTranslationView(numericPostId);
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
    debugLog("User not logged in, skipping");
    return;
  }

  debugLog("Initializing for user:", currentUser.username);

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
