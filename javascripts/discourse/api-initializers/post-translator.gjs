import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";

// State management for tracking translations per post ID
const translationState = new Map();

// Global translation state
let globalState = {
  isTranslating: false,
  allTranslated: false,
  currentLang: null,
  progress: { current: 0, total: 0 },
  abortController: null,
};

// Supported target languages
const SUPPORTED_LANGUAGES = [
  { code: "en", label: "English" },
  { code: "ko", label: "한국어" },
  { code: "zh", label: "中文" },
];

// Reference to the component instance for state updates
let componentInstance = null;

/**
 * Call the translation API for a single post
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

  // Store abort controller for cancellation
  globalState.abortController = controller;

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
      console.error("[Post Translator] Request timeout or cancelled");
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
 * Translate a single post and update its DOM
 */
async function translateSinglePost(postId, targetLang) {
  const elements = getOrCreateTranslationContainer(postId);
  if (!elements) {
    console.error("[Post Translator] Could not find elements for post", postId);
    return false;
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

  // Use cached translation if available for the same language
  if (state.translatedHTML && state.translatedLang === targetLang) {
    container.innerHTML = state.translatedHTML;
    cookedElement.style.display = "none";
    container.style.display = "";
    state.isTranslated = true;
    return true;
  }

  // Call API
  const result = await translatePost(postId, targetLang);

  if (result.success) {
    state.translatedHTML = result.translatedText;
    state.translatedLang = targetLang;
    container.innerHTML = state.translatedHTML;
    cookedElement.style.display = "none";
    container.style.display = "";
    state.isTranslated = true;
    return true;
  }

  return false;
}

/**
 * Show original content for a single post
 */
function showOriginalPost(postId) {
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  if (!article) return;

  const cookedElement = article.querySelector(".cooked");
  const container = article.querySelector(".post-translator-content");

  if (cookedElement) cookedElement.style.display = "";
  if (container) container.style.display = "none";

  const state = translationState.get(postId);
  if (state) state.isTranslated = false;
}

/**
 * Show original content for all posts
 */
function showAllOriginal() {
  const posts = document.querySelectorAll(".topic-post article[data-post-id]");
  posts.forEach((article) => {
    const postId = parseInt(article.dataset.postId);
    showOriginalPost(postId);
  });
  globalState.allTranslated = false;
  globalState.currentLang = null;
}

/**
 * Translate all posts sequentially (one at a time)
 */
async function translateAllPostsSequentially(targetLang, updateCallback) {
  const postElements = document.querySelectorAll(".topic-post article[data-post-id]");
  const total = postElements.length;

  if (total === 0) {
    console.log("[Post Translator] No posts found to translate");
    return false;
  }

  globalState.isTranslating = true;
  globalState.progress.total = total;
  globalState.progress.current = 0;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Starting sequential translation of ${total} posts`);
  }

  let successCount = 0;

  // Sequential translation using for loop with await
  for (let i = 0; i < total; i++) {
    // Check if cancelled
    if (globalState.abortController?.signal.aborted) {
      console.log("[Post Translator] Translation cancelled");
      break;
    }

    const article = postElements[i];
    const postId = parseInt(article.dataset.postId);

    globalState.progress.current = i + 1;
    if (updateCallback) updateCallback();

    if (settings.debug_mode) {
      console.log(`[Post Translator] Translating post ${i + 1}/${total} (ID: ${postId})`);
    }

    const success = await translateSinglePost(postId, targetLang);
    if (success) successCount++;
  }

  globalState.isTranslating = false;
  globalState.allTranslated = successCount > 0;
  globalState.currentLang = targetLang;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Translation complete. ${successCount}/${total} posts translated.`);
  }

  if (updateCallback) updateCallback();
  return true;
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
 * Glimmer component for "Translate All" button
 */
class TranslateAllButton extends Component {
  @tracked isTranslating = false;
  @tracked allTranslated = false;
  @tracked showDropdown = false;
  @tracked currentProgress = 0;
  @tracked totalPosts = 0;
  @tracked currentLang = null;

  constructor() {
    super(...arguments);
    componentInstance = this;
    this.syncFromGlobalState();
  }

  syncFromGlobalState() {
    this.isTranslating = globalState.isTranslating;
    this.allTranslated = globalState.allTranslated;
    this.currentProgress = globalState.progress.current;
    this.totalPosts = globalState.progress.total;
    this.currentLang = globalState.currentLang;
  }

  get buttonLabel() {
    if (this.isTranslating) {
      return i18n(themePrefix("post_translator.translating_progress"), {
        current: this.currentProgress,
        total: this.totalPosts,
      });
    }
    if (this.allTranslated) {
      return i18n(themePrefix("post_translator.show_original_button"));
    }
    return i18n(themePrefix("post_translator.translate_all_button"));
  }

  get showCaret() {
    return !this.isTranslating && !this.allTranslated;
  }

  @action
  handleButtonClick(event) {
    event.preventDefault();
    event.stopPropagation();

    if (this.isTranslating) return;

    if (this.allTranslated) {
      showAllOriginal();
      this.allTranslated = false;
      this.currentLang = null;
    } else {
      this.showDropdown = !this.showDropdown;
    }
  }

  @action
  async selectLanguage(langCode, event) {
    event.preventDefault();
    event.stopPropagation();

    this.showDropdown = false;
    this.isTranslating = true;

    const updateUI = () => {
      this.syncFromGlobalState();
    };

    await translateAllPostsSequentially(langCode, updateUI);

    this.syncFromGlobalState();
  }

  @action
  closeDropdown() {
    this.showDropdown = false;
  }

  <template>
    <div class="translate-all-container">
      <div class="post-translate-dropdown {{if this.showDropdown 'is-open'}}">
        <button
          class="btn btn-flat post-translate-btn"
          type="button"
          disabled={{this.isTranslating}}
          {{on "click" this.handleButtonClick}}
        >
          <svg class="fa d-icon d-icon-globe svg-icon svg-string" xmlns="http://www.w3.org/2000/svg"><use href="#globe"></use></svg>
          <span class="d-button-label">{{this.buttonLabel}}</span>
          {{#if this.showCaret}}
            <svg class="fa d-icon d-icon-caret-down svg-icon svg-string dropdown-caret" xmlns="http://www.w3.org/2000/svg"><use href="#caret-down"></use></svg>
          {{/if}}
        </button>

        <div class="post-translate-menu">
          {{#each this.languages as |lang|}}
            <button
              class="post-translate-menu-item"
              type="button"
              {{on "click" (fn this.selectLanguage lang.code)}}
            >
              {{lang.label}}
            </button>
          {{/each}}
        </div>
      </div>
    </div>
  </template>

  get languages() {
    return SUPPORTED_LANGUAGES;
  }
}

export default apiInitializer("1.1.0", (api) => {
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

  // Setup global dropdown close handler
  setupDropdownCloseHandler();

  // Reset global state on page change
  api.onPageChange(() => {
    // Reset translation state for new topic
    globalState.isTranslating = false;
    globalState.allTranslated = false;
    globalState.currentLang = null;
    globalState.progress = { current: 0, total: 0 };

    // Update component if it exists
    if (componentInstance) {
      componentInstance.syncFromGlobalState();
    }
  });

  // Render the Translate All button at the top of the topic
  api.renderInOutlet("topic-above-post-stream", TranslateAllButton);
});
