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

// API reference for container.lookup access (needed for postStream)
let apiReference = null;

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

  // 1. Try to get HTML from postStream.posts first (works for virtual scrolling)
  const topicController = apiReference?.container?.lookup("controller:topic");
  const posts = topicController?.model?.postStream?.posts || [];
  const postModel = posts.find((p) => p.id === postId);
  let originalHTML = postModel?.cooked;

  if (settings.debug_mode && postModel) {
    console.log("[Post Translator] Found post in postStream model");
  }

  // 2. Fallback to DOM if not in model (for rendered posts)
  if (!originalHTML) {
    const article = document.querySelector(`article[data-post-id="${postId}"]`);
    originalHTML = article?.querySelector(".cooked")?.innerHTML;
    if (settings.debug_mode && originalHTML) {
      console.log("[Post Translator] Found post in DOM (fallback)");
    }
  }

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
 * Apply translation to DOM if the post is currently rendered
 * Returns true if applied, false if post not in DOM
 */
function applyTranslationToDOM(postId, translatedHTML) {
  const elements = getOrCreateTranslationContainer(postId);
  if (!elements) return false; // Post not in DOM (will be applied when scrolled into view)

  const { cookedElement, container } = elements;
  container.innerHTML = translatedHTML;
  cookedElement.style.display = "none";
  container.style.display = "";
  return true;
}

/**
 * Show original content in DOM for a post
 */
function showOriginalInDOM(postId) {
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  if (!article) return false;

  const cookedElement = article.querySelector(".cooked");
  const container = article.querySelector(".post-translator-content");

  if (cookedElement) cookedElement.style.display = "";
  if (container) container.style.display = "none";
  return true;
}

/**
 * Translate a single post and update its DOM
 */
async function translateSinglePost(postId, targetLang) {
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
    state.isTranslated = true;
    applyTranslationToDOM(postId, state.translatedHTML);
    return true;
  }

  // Call API
  const result = await translatePost(postId, targetLang);

  if (result.success) {
    state.translatedHTML = result.translatedText;
    state.translatedLang = targetLang;
    state.isTranslated = true;
    applyTranslationToDOM(postId, state.translatedHTML);
    return true;
  }

  return false;
}

/**
 * Show original content for a single post (updates state and DOM if present)
 */
function showOriginalPost(postId) {
  const state = translationState.get(postId);
  if (state) state.isTranslated = false;
  showOriginalInDOM(postId);
}

/**
 * Show original content for all posts (both cached and DOM)
 */
function showAllOriginal() {
  // Update all cached translation states
  translationState.forEach((state, postId) => {
    state.isTranslated = false;
    // Apply to DOM if post is currently rendered
    showOriginalInDOM(postId);
  });

  globalState.allTranslated = false;
  globalState.currentLang = null;
}

/**
 * Translate all posts sequentially (one at a time)
 * Uses postStream.stream to get all post IDs (not just DOM-rendered ones)
 */
async function translateAllPostsSequentially(targetLang, updateCallback) {
  // Get all post IDs from postStream (handles virtual scrolling)
  const topicController = apiReference?.container?.lookup("controller:topic");
  const postStream = topicController?.model?.postStream;

  if (!postStream) {
    console.log("[Post Translator] PostStream not found");
    return false;
  }

  // stream contains all post IDs in the topic
  const allPostIds = postStream.stream || [];
  const total = allPostIds.length;

  if (total === 0) {
    console.log("[Post Translator] No posts found to translate");
    return false;
  }

  if (settings.debug_mode) {
    console.log(`[Post Translator] Found ${total} posts in postStream`);
    console.log(`[Post Translator] Loaded posts: ${postStream.posts?.length || 0}`);
  }

  globalState.isTranslating = true;
  globalState.progress.total = total;
  globalState.progress.current = 0;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Starting sequential translation of ${total} posts`);
  }

  let successCount = 0;
  let skippedCount = 0;

  // Sequential translation using for loop with await
  for (let i = 0; i < total; i++) {
    // Check if cancelled
    if (globalState.abortController?.signal.aborted) {
      console.log("[Post Translator] Translation cancelled");
      break;
    }

    const postId = allPostIds[i];

    globalState.progress.current = i + 1;
    if (updateCallback) updateCallback();

    if (settings.debug_mode) {
      console.log(`[Post Translator] Translating post ${i + 1}/${total} (ID: ${postId})`);
    }

    const success = await translateSinglePost(postId, targetLang);
    if (success) {
      successCount++;
    } else {
      skippedCount++;
      if (settings.debug_mode) {
        console.log(`[Post Translator] Skipped post ${postId} (content not available)`);
      }
    }
  }

  globalState.isTranslating = false;
  globalState.allTranslated = successCount > 0;
  globalState.currentLang = targetLang;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Translation complete. ${successCount}/${total} posts translated, ${skippedCount} skipped.`);
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
 * Setup MutationObserver to apply cached translations when posts are rendered
 * This handles virtual scrolling - when user scrolls, new posts appear in DOM
 */
function setupTranslationObserver() {
  const container = document.querySelector("#main-outlet, .topic-area");
  if (!container) return null;

  const observer = new MutationObserver((mutations) => {
    // Only apply if translation is active
    if (!globalState.allTranslated) return;

    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (node.nodeType !== 1) return; // Not an element

        // Find newly rendered posts
        const articles = node.matches?.("article[data-post-id]")
          ? [node]
          : node.querySelectorAll?.("article[data-post-id]") || [];

        articles.forEach((article) => {
          const postId = parseInt(article.dataset.postId);
          const state = translationState.get(postId);

          // Apply cached translation if this post was translated
          if (state?.isTranslated && state?.translatedHTML) {
            if (settings.debug_mode) {
              console.log(`[Post Translator] Applying cached translation to post ${postId} (virtual scroll)`);
            }
            applyTranslationToDOM(postId, state.translatedHTML);
          }
        });
      });
    }
  });

  observer.observe(container, { childList: true, subtree: true });

  if (settings.debug_mode) {
    console.log("[Post Translator] Translation observer setup complete");
  }

  return observer;
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

export default apiInitializer("1.2.0", (api) => {
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

  // Store API reference for postStream access
  apiReference = api;

  // Setup global dropdown close handler
  setupDropdownCloseHandler();

  // Track translation observer for cleanup
  let translationObserver = null;

  // Reset global state on page change
  api.onPageChange(() => {
    // Cleanup previous observer
    if (translationObserver) {
      translationObserver.disconnect();
      translationObserver = null;
    }

    // Reset translation state for new topic
    globalState.isTranslating = false;
    globalState.allTranslated = false;
    globalState.currentLang = null;
    globalState.progress = { current: 0, total: 0 };

    // Clear translation cache for new topic
    translationState.clear();

    // Update component if it exists
    if (componentInstance) {
      componentInstance.syncFromGlobalState();
    }

    // Setup new observer after a short delay (wait for topic to render)
    setTimeout(() => {
      translationObserver = setupTranslationObserver();
    }, 500);
  });

  // Render the Translate All button at the top of the topic
  api.renderInOutlet("topic-above-post-stream", TranslateAllButton);
});
