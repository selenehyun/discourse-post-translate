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

// Title translation state
let titleState = {
  isTranslated: false,
  originalTitle: null,        // Original plain text
  originalFancyTitle: null,   // Original HTML (fancy_title)
  translatedTitle: null,      // Translated text
  translatedLang: null,       // Cached translation language
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
 * Translate the topic title
 */
async function translateTitle(targetLang) {
  const topicController = apiReference?.container?.lookup("controller:topic");
  const originalTitle = topicController?.model?.title;

  if (!originalTitle) {
    if (settings.debug_mode) {
      console.log("[Post Translator] Title not found");
    }
    return { success: false, error: "Title not found" };
  }

  // Cache original title on first call
  if (!titleState.originalTitle) {
    titleState.originalTitle = originalTitle;
    titleState.originalFancyTitle = topicController?.model?.fancy_title;
  }

  // Use cached translation if available for the same language
  if (titleState.translatedTitle && titleState.translatedLang === targetLang) {
    if (settings.debug_mode) {
      console.log("[Post Translator] Using cached title translation");
    }
    return { success: true, translatedText: titleState.translatedTitle };
  }

  if (settings.debug_mode) {
    console.log("[Post Translator] Translating title:", originalTitle);
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

    if (settings.translation_api_key) {
      headers["X-API-Key"] = settings.translation_api_key;
    }

    const response = await fetch(settings.translation_api_url, {
      method: "POST",
      headers,
      body: JSON.stringify({
        content: originalTitle,
        sourceLang: "auto",
        targetLang: targetLang,
        format: "text",  // Title is plain text
        mode: "fast",
      }),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    const data = await response.json();

    if (settings.debug_mode) {
      console.log("[Post Translator] Title API Response:", data);
    }

    if (!response.ok) {
      return {
        success: false,
        error: data.error || "Title translation failed",
      };
    }

    // Cache the translated title
    titleState.translatedTitle = data.translated;
    titleState.translatedLang = targetLang;

    return {
      success: true,
      translatedText: data.translated,
    };
  } catch (error) {
    clearTimeout(timeoutId);

    if (error.name === "AbortError") {
      return { success: false, error: "Request timeout" };
    }

    return { success: false, error: error.message || "Network error" };
  }
}

/**
 * Apply translated title to DOM elements
 */
function applyTitleTranslation(translatedText) {
  // Update main title
  const mainTitle = document.querySelector("#topic-title .fancy-title");
  if (mainTitle) {
    mainTitle.textContent = translatedText;
    if (settings.debug_mode) {
      console.log("[Post Translator] Applied translation to main title");
    }
  }

  // Update sticky header title (if visible)
  const stickyTitle = document.querySelector(".extra-info-wrapper .topic-link");
  if (stickyTitle) {
    stickyTitle.textContent = translatedText;
    if (settings.debug_mode) {
      console.log("[Post Translator] Applied translation to sticky header title");
    }
  }

  titleState.isTranslated = true;
}

/**
 * Restore original title in DOM
 */
function showOriginalTitle() {
  if (!titleState.originalTitle) return;

  // Restore main title
  const mainTitle = document.querySelector("#topic-title .fancy-title");
  if (mainTitle) {
    mainTitle.innerHTML = titleState.originalFancyTitle || titleState.originalTitle;
  }

  // Restore sticky header title
  const stickyTitle = document.querySelector(".extra-info-wrapper .topic-link");
  if (stickyTitle) {
    stickyTitle.textContent = titleState.originalTitle;
  }

  titleState.isTranslated = false;

  if (settings.debug_mode) {
    console.log("[Post Translator] Restored original title");
  }
}

/**
 * Setup MutationObserver for sticky header to apply translated title when it appears
 */
function setupStickyHeaderObserver() {
  const header = document.querySelector(".d-header");
  if (!header) return null;

  const observer = new MutationObserver((mutations) => {
    // Only apply if title is translated and we have the translated text
    if (!titleState.isTranslated || !titleState.translatedTitle) return;

    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (node.nodeType !== 1) return; // Not an element

        // Check if .extra-info-wrapper was added
        const stickyWrapper = node.matches?.(".extra-info-wrapper")
          ? node
          : node.querySelector?.(".extra-info-wrapper");

        if (stickyWrapper) {
          const topicLink = stickyWrapper.querySelector(".topic-link");
          if (topicLink) {
            topicLink.textContent = titleState.translatedTitle;
            if (settings.debug_mode) {
              console.log("[Post Translator] Applied translated title to sticky header (observer)");
            }
          }
        }
      });
    }
  });

  observer.observe(header, { childList: true, subtree: true });

  if (settings.debug_mode) {
    console.log("[Post Translator] Sticky header observer setup complete");
  }

  return observer;
}

/**
 * Get or create translation container for a post
 * Returns article reference for CSS class-based visibility control
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
    // Note: display is controlled via CSS (.is-translated class on article)
    cookedElement.parentNode.insertBefore(container, cookedElement.nextSibling);
  }

  return { cookedElement, container, article };
}

/**
 * Apply translation to DOM if the post is currently rendered
 * Returns true if applied, false if post not in DOM
 * Uses CSS class for visibility control to avoid Glimmer DOM conflicts
 */
function applyTranslationToDOM(postId, translatedHTML) {
  const elements = getOrCreateTranslationContainer(postId);
  if (!elements) return false; // Post not in DOM (will be applied when scrolled into view)

  const { container, article } = elements;
  container.innerHTML = translatedHTML;

  // Use CSS class for visibility control (no inline style modifications)
  article.classList.add("is-translated");

  return true;
}

/**
 * Show original content in DOM for a post
 * Uses CSS class removal for visibility control to avoid Glimmer DOM conflicts
 */
function showOriginalInDOM(postId) {
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  if (!article) return false;

  // Remove CSS class to show original content (no inline style modifications)
  article.classList.remove("is-translated");

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
  // Restore title first
  showOriginalTitle();

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
  const postCount = allPostIds.length;

  if (postCount === 0) {
    console.log("[Post Translator] No posts found to translate");
    return false;
  }

  // Total = posts + 1 (title)
  const total = postCount + 1;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Found ${postCount} posts in postStream`);
    console.log(`[Post Translator] Loaded posts: ${postStream.posts?.length || 0}`);
    console.log(`[Post Translator] Total items to translate: ${total} (including title)`);
  }

  globalState.isTranslating = true;
  globalState.progress.total = total;
  globalState.progress.current = 0;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Starting sequential translation`);
  }

  let successCount = 0;
  let skippedCount = 0;

  // === Step 1: Translate title first ===
  globalState.progress.current = 1;
  if (updateCallback) updateCallback();

  if (settings.debug_mode) {
    console.log(`[Post Translator] Translating title (1/${total})`);
  }

  const titleResult = await translateTitle(targetLang);
  if (titleResult.success) {
    applyTitleTranslation(titleResult.translatedText);
    successCount++;
  } else {
    skippedCount++;
    if (settings.debug_mode) {
      console.log(`[Post Translator] Title translation skipped: ${titleResult.error}`);
    }
  }

  // === Step 2: Translate posts sequentially ===
  for (let i = 0; i < postCount; i++) {
    // Check if cancelled
    if (globalState.abortController?.signal.aborted) {
      console.log("[Post Translator] Translation cancelled");
      break;
    }

    const postId = allPostIds[i];

    // Progress: +2 because title is 1, first post is 2
    globalState.progress.current = i + 2;
    if (updateCallback) updateCallback();

    if (settings.debug_mode) {
      console.log(`[Post Translator] Translating post ${i + 2}/${total} (ID: ${postId})`);
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
    console.log(`[Post Translator] Translation complete. ${successCount}/${total} items translated, ${skippedCount} skipped.`);
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
    // Apply cached translations during translation OR after completion
    if (!globalState.isTranslating && !globalState.allTranslated) return;

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

export default apiInitializer("1.4.0", (api) => {
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

  // Track observers for cleanup
  let translationObserver = null;
  let stickyHeaderObserver = null;

  // Reset global state on page change
  api.onPageChange(() => {
    // === CSS class cleanup (before Glimmer teardown) ===
    // Remove .is-translated class from all articles to prevent DOM conflicts
    document.querySelectorAll("article.is-translated").forEach((article) => {
      article.classList.remove("is-translated");
    });

    // Remove translation containers (clean DOM before Glimmer teardown)
    document.querySelectorAll(".post-translator-content").forEach((el) => {
      el.remove();
    });

    // Cleanup previous observers
    if (translationObserver) {
      translationObserver.disconnect();
      translationObserver = null;
    }
    if (stickyHeaderObserver) {
      stickyHeaderObserver.disconnect();
      stickyHeaderObserver = null;
    }

    // Reset translation state for new topic
    globalState.isTranslating = false;
    globalState.allTranslated = false;
    globalState.currentLang = null;
    globalState.progress = { current: 0, total: 0 };

    // Reset title state for new topic
    titleState = {
      isTranslated: false,
      originalTitle: null,
      originalFancyTitle: null,
      translatedTitle: null,
      translatedLang: null,
    };

    // Clear translation cache for new topic
    translationState.clear();

    // Update component if it exists
    if (componentInstance) {
      componentInstance.syncFromGlobalState();
    }

    // Setup new observers after a short delay (wait for topic to render)
    setTimeout(() => {
      translationObserver = setupTranslationObserver();
      stickyHeaderObserver = setupStickyHeaderObserver();
    }, 500);
  });

  // Render the Translate All button at the top of the topic
  api.renderInOutlet("topic-above-post-stream", TranslateAllButton);
});
