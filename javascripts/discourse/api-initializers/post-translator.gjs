import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";

// State management for tracking translations per post ID
// Structure: { isTranslated, translatedHTML, translatedLang, originalCooked }
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
  originalTitle: null,        // Original plain text (from model)
  originalFancyTitle: null,   // Original HTML (fancy_title from model)
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
 * Apply translated title via Topic Model (Glimmer-safe)
 * Falls back to DOM manipulation if model update fails
 */
function applyTitleTranslation(translatedText) {
  const topicController = apiReference?.container?.lookup("controller:topic");
  const topicModel = topicController?.model;

  if (topicModel) {
    // Cache original if not already cached
    if (!titleState.originalTitle) {
      titleState.originalTitle = topicModel.title;
      titleState.originalFancyTitle = topicModel.fancy_title;
    }

    // Update model - Glimmer will auto-render
    topicModel.set("title", translatedText);
    topicModel.set("fancy_title", translatedText);

    if (settings.debug_mode) {
      console.log("[Post Translator] Applied title translation via Model");
    }
  } else {
    // Fallback to DOM if model not available
    const mainTitle = document.querySelector("#topic-title .fancy-title");
    if (mainTitle) {
      mainTitle.textContent = translatedText;
      if (settings.debug_mode) {
        console.log("[Post Translator] Applied title translation via DOM (fallback)");
      }
    }
  }

  titleState.isTranslated = true;
}

/**
 * Restore original title via Topic Model (Glimmer-safe)
 */
function showOriginalTitle() {
  if (!titleState.originalTitle) return;

  const topicController = apiReference?.container?.lookup("controller:topic");
  const topicModel = topicController?.model;

  if (topicModel) {
    // Restore via model - Glimmer will auto-render
    topicModel.set("title", titleState.originalTitle);
    topicModel.set("fancy_title", titleState.originalFancyTitle);

    if (settings.debug_mode) {
      console.log("[Post Translator] Restored original title via Model");
    }
  } else {
    // Fallback to DOM
    const mainTitle = document.querySelector("#topic-title .fancy-title");
    if (mainTitle) {
      mainTitle.innerHTML = titleState.originalFancyTitle || titleState.originalTitle;
    }
  }

  titleState.isTranslated = false;
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
 * Apply translation via Post Model (Glimmer-safe)
 * Updates post.cooked which triggers Glimmer re-render automatically
 * This approach avoids DOM conflicts during page transitions
 */
function applyTranslation(postId, translatedHTML) {
  const topicController = apiReference?.container?.lookup("controller:topic");
  const postStream = topicController?.model?.postStream;
  const posts = postStream?.posts || [];
  const postModel = posts.find((p) => p.id === postId);

  // Get or create state
  let state = translationState.get(postId);
  if (!state) {
    state = {
      isTranslated: false,
      translatedHTML: null,
      translatedLang: null,
      originalCooked: null,
    };
    translationState.set(postId, state);
  }

  if (postModel) {
    // Cache original cooked on first access
    if (!state.originalCooked) {
      state.originalCooked = postModel.cooked;
    }

    // Update model - Glimmer will auto-render
    postModel.set("cooked", translatedHTML);

    if (settings.debug_mode) {
      console.log(`[Post Translator] Applied translation to post ${postId} via Model`);
    }
    return true;
  }

  // Fallback to DOM if model not available (edge case)
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  if (!article) return false;

  const cookedElement = article.querySelector(".cooked");
  if (!cookedElement) return false;

  // Cache original from DOM as fallback
  if (!state.originalCooked) {
    state.originalCooked = cookedElement.innerHTML;
  }

  cookedElement.innerHTML = translatedHTML;

  if (settings.debug_mode) {
    console.log(`[Post Translator] Applied translation to post ${postId} via DOM (fallback)`);
  }
  return true;
}

/**
 * Restore original content via Post Model (Glimmer-safe)
 */
function showOriginal(postId) {
  const state = translationState.get(postId);
  if (!state?.originalCooked) return false;

  const topicController = apiReference?.container?.lookup("controller:topic");
  const postStream = topicController?.model?.postStream;
  const posts = postStream?.posts || [];
  const postModel = posts.find((p) => p.id === postId);

  if (postModel) {
    // Restore via model - Glimmer will auto-render
    postModel.set("cooked", state.originalCooked);

    if (settings.debug_mode) {
      console.log(`[Post Translator] Restored original for post ${postId} via Model`);
    }
    return true;
  }

  // Fallback to DOM
  const article = document.querySelector(`article[data-post-id="${postId}"]`);
  const cookedElement = article?.querySelector(".cooked");

  if (cookedElement) {
    cookedElement.innerHTML = state.originalCooked;

    if (settings.debug_mode) {
      console.log(`[Post Translator] Restored original for post ${postId} via DOM (fallback)`);
    }
    return true;
  }

  return false;
}

/**
 * Translate a single post and update via Model
 */
async function translateSinglePost(postId, targetLang) {
  let state = translationState.get(postId);
  if (!state) {
    state = {
      isTranslated: false,
      translatedHTML: null,
      translatedLang: null,
      originalCooked: null,
    };
    translationState.set(postId, state);
  }

  // Use cached translation if available for the same language
  if (state.translatedHTML && state.translatedLang === targetLang) {
    state.isTranslated = true;
    applyTranslation(postId, state.translatedHTML);
    return true;
  }

  // Call API
  const result = await translatePost(postId, targetLang);

  if (result.success) {
    state.translatedHTML = result.translatedText;
    state.translatedLang = targetLang;
    state.isTranslated = true;
    applyTranslation(postId, state.translatedHTML);
    return true;
  }

  return false;
}

/**
 * Show original content for a single post (updates state and Model)
 */
function showOriginalPost(postId) {
  const state = translationState.get(postId);
  if (state) state.isTranslated = false;
  showOriginal(postId);
}

/**
 * Show original content for all posts via Model
 */
function showAllOriginal() {
  // Restore title first
  showOriginalTitle();

  // Update all cached translation states and restore via Model
  translationState.forEach((state, postId) => {
    state.isTranslated = false;
    showOriginal(postId);
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
 * Setup observer to apply cached translations when new posts are loaded
 * With Model-based approach, Glimmer handles re-renders automatically.
 * This observer only ensures translations are applied to NEWLY LOADED posts
 * (posts fetched from server as user scrolls to unloaded content)
 */
function setupTranslationObserver() {
  const container = document.querySelector("#main-outlet, .topic-area");
  if (!container) return null;

  const observer = new MutationObserver((mutations) => {
    // Only act if we have translations active
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

          // Apply cached translation via Model if this post was translated
          if (state?.isTranslated && state?.translatedHTML) {
            if (settings.debug_mode) {
              console.log(`[Post Translator] Applying cached translation to post ${postId} via Model (scroll)`);
            }
            applyTranslation(postId, state.translatedHTML);
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

export default apiInitializer("1.6.0", (api) => {
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

  console.log("[Post Translator] Initializing v1.6.0 (Model-based) for user:", currentUser.username);

  // Store API reference for postStream access
  apiReference = api;

  // Setup global dropdown close handler
  setupDropdownCloseHandler();

  // Track observers for cleanup
  let translationObserver = null;
  let stickyHeaderObserver = null;

  // === routeWillChange: State reset BEFORE navigation ===
  // With Model-based approach, we just reset state - no DOM cleanup needed
  // Glimmer handles all DOM lifecycle automatically
  const router = api.container.lookup("service:router");
  router.on("routeWillChange", () => {
    if (settings.debug_mode) {
      console.log("[Post Translator] routeWillChange: resetting state (Model-based approach)");
    }

    // Clear translation state - Model changes don't persist across routes
    translationState.clear();

    // Reset global state
    globalState = {
      isTranslating: false,
      allTranslated: false,
      currentLang: null,
      progress: { current: 0, total: 0 },
      abortController: null,
    };

    // Reset title state
    titleState = {
      isTranslated: false,
      originalTitle: null,
      originalFancyTitle: null,
      translatedTitle: null,
      translatedLang: null,
    };

    // Update component if it exists
    if (componentInstance) {
      componentInstance.syncFromGlobalState();
    }
  });

  // === onPageChange: Observer setup only ===
  // With Model-based approach, no DOM restoration needed
  // Observers are only for applying translations to newly loaded posts
  api.onPageChange(() => {
    // Cleanup previous observers
    if (translationObserver) {
      translationObserver.disconnect();
      translationObserver = null;
    }
    if (stickyHeaderObserver) {
      stickyHeaderObserver.disconnect();
      stickyHeaderObserver = null;
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
