import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

// State management for tracking translations per post ID
const translationState = new Map();
// Track which posts have buttons to avoid duplicates
const buttonsAdded = new Set();

// Supported target languages
const SUPPORTED_LANGUAGES = [
  { code: "en", label: "English" },
  { code: "ko", label: "한국어" },
  { code: "zh", label: "中文" },
];

/**
 * Call the translation API
 */
async function translatePost(postId, targetLang) {
  if (settings.debug_mode) {
    console.log("[Post Translator] Calling API");
    console.log("[Post Translator] Post ID:", postId);
    console.log("[Post Translator] Target language:", targetLang);
    console.log("[Post Translator] API URL:", settings.translation_api_url);
  }

  // Get original HTML content from the post
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  const cookedElement = article?.querySelector(".cooked");
  const originalHTML = cookedElement?.innerHTML;

  if (!originalHTML) {
    console.error("[Post Translator] Could not find content for post", postId);
    return { success: false, error: "Content not found" };
  }

  if (settings.debug_mode) {
    console.log("[Post Translator] Content length:", originalHTML.length);
  }

  // Setup timeout with AbortController
  const controller = new AbortController();
  const timeoutId = setTimeout(
    () => controller.abort(),
    settings.translation_api_timeout
  );

  try {
    const headers = {
      "Content-Type": "application/json",
    };

    // Add API key if configured
    if (settings.translation_api_key) {
      headers["X-API-Key"] = settings.translation_api_key;
    }

    const response = await fetch(settings.translation_api_url, {
      method: "POST",
      headers,
      body: JSON.stringify({
        content: originalHTML,
        sourceLang: "auto",
        targetLang: targetLang,
        format: "html",
        mode: "fast",
      }),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    const data = await response.json();

    if (settings.debug_mode) {
      console.log("[Post Translator] API Response status:", response.status);
      console.log("[Post Translator] API Response data:", data);
    }

    if (!response.ok) {
      console.error("[Post Translator] API Error:", data.error, data.code);
      return {
        success: false,
        error: data.error || "Translation failed",
        code: data.code,
      };
    }

    return {
      success: true,
      translatedText: data.translated,
      quality: data.quality,
      provider: data.provider,
    };
  } catch (error) {
    clearTimeout(timeoutId);

    if (error.name === "AbortError") {
      console.error("[Post Translator] Request timeout");
      return { success: false, error: "Request timeout" };
    }

    console.error("[Post Translator] Network error:", error);
    return { success: false, error: error.message || "Network error" };
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
 * Handle translation for a specific language
 */
async function handleTranslate(postId, targetLang, buttonContainer) {
  console.log("[Post Translator] handleTranslate called for post:", postId, "lang:", targetLang);

  const elements = getOrCreateTranslationContainer(postId);
  if (!elements) {
    console.error("[Post Translator] Could not find elements for post", postId);
    return;
  }

  const { cookedElement, container } = elements;

  let state = translationState.get(postId);
  if (!state) {
    state = {
      isTranslated: false,
      translatedHTML: null,
      translatedLang: null,
    };
    translationState.set(postId, state);
  }

  const mainButton = buttonContainer.querySelector(".post-translate-btn");
  const labelSpan = mainButton?.querySelector(".d-button-label");

  // If already showing translation in same language, toggle back to original
  if (state.isTranslated && state.translatedLang === targetLang) {
    cookedElement.style.display = "";
    container.style.display = "none";
    state.isTranslated = false;
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.translate_button"));
    }
    return;
  }

  // Use cached translation if available for the same language
  if (state.translatedHTML && state.translatedLang === targetLang) {
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
  if (mainButton) mainButton.disabled = true;
  if (labelSpan) {
    labelSpan.textContent = i18n(themePrefix("post_translator.translating"));
  }

  // Call API with selected language
  const result = await translatePost(postId, targetLang);

  if (mainButton) mainButton.disabled = false;

  if (result.success) {
    state.translatedHTML = result.translatedText;
    state.translatedLang = targetLang;
    container.innerHTML = state.translatedHTML;
    cookedElement.style.display = "none";
    container.style.display = "";
    state.isTranslated = true;
    if (labelSpan) {
      labelSpan.textContent = i18n(themePrefix("post_translator.show_original_button"));
    }
  } else {
    // Determine appropriate error message based on error type
    let errorMessage;
    if (result.error === "Request timeout") {
      errorMessage = i18n(themePrefix("post_translator.error_timeout"));
    } else if (result.error === "Network error" || result.error?.includes("fetch")) {
      errorMessage = i18n(themePrefix("post_translator.error_network"));
    } else {
      errorMessage = i18n(themePrefix("post_translator.error_generic"));
    }

    // Show error message briefly in button, then restore
    if (labelSpan) {
      labelSpan.textContent = errorMessage;
      setTimeout(() => {
        labelSpan.textContent = i18n(themePrefix("post_translator.translate_button"));
      }, 3000);
    }
  }
}

/**
 * Toggle dropdown menu visibility
 */
function toggleDropdown(dropdown) {
  const isOpen = dropdown.classList.contains("is-open");
  // Close all other dropdowns first
  document.querySelectorAll(".post-translate-dropdown.is-open").forEach((d) => {
    d.classList.remove("is-open");
  });
  if (!isOpen) {
    dropdown.classList.add("is-open");
  }
}

/**
 * Close all dropdowns when clicking outside
 */
let dropdownHandlerSetup = false;
function setupDropdownCloseHandler() {
  if (dropdownHandlerSetup) return;
  dropdownHandlerSetup = true;

  document.addEventListener("click", (e) => {
    if (!e.target.closest(".post-translate-dropdown")) {
      document.querySelectorAll(".post-translate-dropdown.is-open").forEach((d) => {
        d.classList.remove("is-open");
      });
    }
  });
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
 * Add translate button with language dropdown to a single post
 */
function addButtonToPost(post) {
  const articleElement = post.querySelector("article[data-post-id]");
  if (!articleElement) return;

  const postId = articleElement.dataset.postId;
  if (!postId) return;

  const numericPostId = parseInt(postId);
  const actionsContainer = post.querySelector(".post-controls .actions");
  if (!actionsContainer) return;

  // Check if dropdown already exists in DOM
  if (actionsContainer.querySelector(".post-translate-dropdown")) {
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

  // Create dropdown container
  const dropdown = document.createElement("div");
  dropdown.className = "post-translate-dropdown";

  // Create main button
  const mainButton = document.createElement("button");
  mainButton.className = "btn btn-icon-text post-translate-btn btn-flat";
  mainButton.type = "button";
  mainButton.title = label;
  mainButton.innerHTML = `<svg class="fa d-icon d-icon-globe svg-icon svg-string" xmlns="http://www.w3.org/2000/svg"><use href="#globe"></use></svg><span class="d-button-label">${label}</span><svg class="fa d-icon d-icon-caret-down svg-icon svg-string dropdown-caret" xmlns="http://www.w3.org/2000/svg"><use href="#caret-down"></use></svg>`;

  // Create dropdown menu
  const menu = document.createElement("div");
  menu.className = "post-translate-menu";

  // Add language options
  SUPPORTED_LANGUAGES.forEach((lang) => {
    const option = document.createElement("button");
    option.className = "post-translate-menu-item";
    option.type = "button";
    option.textContent = lang.label;
    option.dataset.lang = lang.code;

    option.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropdown.classList.remove("is-open");
      handleTranslate(numericPostId, lang.code, dropdown);
    });

    menu.appendChild(option);
  });

  // Toggle dropdown on main button click
  mainButton.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();

    // If currently showing translation, clicking toggles back to original
    const currentState = translationState.get(numericPostId);
    if (currentState?.isTranslated) {
      handleTranslate(numericPostId, currentState.translatedLang, dropdown);
    } else {
      toggleDropdown(dropdown);
    }
  });

  dropdown.appendChild(mainButton);
  dropdown.appendChild(menu);
  actionsContainer.appendChild(dropdown);

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
    console.log("[Post Translator] User not logged in, skipping");
    return;
  }

  console.log("[Post Translator] Initializing for user:", currentUser.username);

  // Setup global dropdown close handler (only once)
  setupDropdownCloseHandler();

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
