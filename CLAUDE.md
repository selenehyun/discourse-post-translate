# Discourse Theme Component Development Guide

This guide covers Discourse theme component development patterns and the Post Translator project structure.

## Project Overview

**Project**: Post Translator
**Type**: Discourse Theme Component
**Minimum Discourse Version**: 3.2.0
**Author**: Tim Kang

### Features
- Add translation button to Discourse posts
- Support for multiple target languages (English, Korean, Chinese)
- Toggle between original and translated content
- Per-post translation state caching

## File Structure

```
cloudbro-discourse/
├── about.json                          # Component metadata
├── settings.yml                        # Admin-configurable settings
├── CLAUDE.md                           # This guide
├── javascripts/
│   └── discourse/
│       └── api-initializers/
│           └── post-translator.gjs     # Main logic
├── common/
│   └── common.scss                     # Component styles
└── locales/
    ├── en.yml                          # English translations
    └── ko.yml                          # Korean translations
```

### File Roles

| File | Purpose |
|------|---------|
| `about.json` | Component metadata (name, version, minimum Discourse version) |
| `settings.yml` | Defines admin-configurable settings with types and defaults |
| `api-initializers/*.gjs` | Entry point for component logic using Discourse Plugin API |
| `common/common.scss` | Styles applied to all color schemes |
| `locales/*.yml` | Internationalization strings |

## Discourse Theme Component Development Patterns

### API Initializer

The primary entry point for theme components. Provides access to Discourse's Plugin API.

```gjs
import { apiInitializer } from "discourse/lib/api";

export default apiInitializer("1.0.0", (api) => {
  // api.getCurrentUser() - Get logged-in user
  // api.onPageChange() - Hook into page navigation
  // api.renderInOutlet() - Render into plugin outlets
  // api.decorateCookedElement() - Modify post content
});
```

**Version parameter**: The first argument (`"1.0.0"`) is the initializer version. Increment when making breaking changes.

### Key API Methods

```javascript
// Get current user
const currentUser = api.getCurrentUser();
if (!currentUser) return; // Not logged in

// Hook into page changes (SPA navigation)
api.onPageChange(() => {
  // Runs on every route transition
});

// Render a Glimmer component in a plugin outlet
api.renderInOutlet("outlet-name", MyComponent);

// Modify rendered post content
api.decorateCookedElement((element, helper) => {
  // element: The post's .cooked element
  // helper: Provides renderGlimmer(), getModel(), etc.
}, { id: "unique-decorator-id" });
```

### Glimmer/GJS Components

Discourse uses Glimmer components with GJS (single-file component) format:

```gjs
import Component from "@glimmer/component";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";

export default class MyComponent extends Component {
  @service currentUser;
  @service siteSettings;

  @tracked isLoading = false;

  @action
  handleClick() {
    this.isLoading = true;
  }

  <template>
    <button {{on "click" this.handleClick}} disabled={{this.isLoading}}>
      {{if this.isLoading "Loading..." "Click Me"}}
    </button>
  </template>
}
```

### Accessing Theme Settings

Theme settings from `settings.yml` are available globally via the `settings` object:

```javascript
if (settings.debug_mode) {
  console.log("Debug enabled");
}

const apiUrl = settings.translation_api_url;
```

### Internationalization (i18n)

```javascript
import { i18n } from "discourse-i18n";

// For theme-specific keys, use themePrefix()
const label = i18n(themePrefix("post_translator.translate_button"));

// The themePrefix() function is automatically available in theme components
```

## Current Implementation Architecture

### MutationObserver Pattern

This project uses MutationObserver instead of the deprecated widget system (removed in Discourse 3.6.0+). This approach handles:

- Virtual scrolling (posts rendered/destroyed dynamically)
- SPA navigation (content changes without page reload)
- Dynamic post loading (infinite scroll)

```javascript
const observer = new MutationObserver((mutations) => {
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
```

### State Management

Per-post state is managed using a Map:

```javascript
const translationState = new Map();

// State structure per post
{
  isTranslated: boolean,      // Currently showing translation?
  translatedHTML: string,     // Cached translated content
  translatedLang: string      // Language of cached translation
}
```

This approach:
- Survives DOM re-renders (virtual scrolling)
- Enables toggle between original/translated
- Caches translations to avoid redundant API calls

### DOM Manipulation Strategy

The project uses vanilla DOM API for post button injection:

```javascript
function addButtonToPost(post) {
  const articleElement = post.querySelector("article[data-post-id]");
  const postId = articleElement.dataset.postId;
  const actionsContainer = post.querySelector(".post-controls .actions");

  // Create and append button elements
  actionsContainer.appendChild(dropdown);
}
```

**Why vanilla DOM instead of Glimmer?**
- Post action buttons require precise DOM placement
- MutationObserver pattern already handles lifecycle
- Simpler state restoration on re-render

## Settings Configuration

### settings.yml Structure

```yaml
setting_name:
  type: string|integer|bool|list|enum
  default: "default value"
  description:
    en: "English description"
    ko: "Korean description"
```

### Available Types

| Type | Description | Example |
|------|-------------|---------|
| `string` | Text input | API URLs, keys |
| `integer` | Number input | Timeouts, limits |
| `bool` | Toggle switch | Feature flags |
| `list` | Comma-separated values | Allowed domains |
| `enum` | Dropdown selection | Mode selection |

### Current Settings

| Setting | Type | Purpose |
|---------|------|---------|
| `translation_api_url` | string | Translation API endpoint |
| `translation_api_key` | string | API authentication key |
| `translation_api_timeout` | integer | Request timeout (ms) |
| `show_translation_button` | bool | Enable/disable feature |
| `debug_mode` | bool | Console logging |

## Locales and Internationalization

### File Structure

```yaml
# locales/en.yml
en:
  post_translator:
    translate_button: "Translate"
    show_original_button: "Show Original"
    translating: "Translating..."
    error_generic: "Translation failed. Please try again."

  theme_metadata:
    settings:
      setting_name: "Setting description for admin UI"
```

### Usage in Code

```javascript
import { i18n } from "discourse-i18n";

// Theme-prefixed key (recommended)
i18n(themePrefix("post_translator.translate_button"))

// The themePrefix() function automatically adds the theme's unique prefix
```

### Adding New Languages

1. Create `locales/{lang_code}.yml`
2. Follow the same structure as `en.yml`
3. Discourse automatically uses the user's locale

## Styling Guide

### Discourse CSS Variables

Use Discourse's built-in CSS variables for theme compatibility:

```scss
// Colors
var(--primary)           // Main text color
var(--secondary)         // Background color
var(--tertiary)          // Accent/link color
var(--primary-low)       // Subtle borders/backgrounds
var(--danger)            // Error states

// Typography
var(--font-down-1)       // Smaller text
var(--font-up-1)         // Larger text

// Spacing
var(--d-font-size-root)  // Base font size
```

### Button Styling

Follow Discourse's button conventions:

```scss
.my-button {
  // Inherit from Discourse's .btn class
  &:hover {
    background-color: var(--primary-low);
  }

  &:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }
}
```

### Z-Index Considerations

Dropdowns and overlays should use appropriate z-index:

```scss
.dropdown-menu {
  z-index: 1000;  // Above post content
}
```

## Development Best Practices

### Virtual Scrolling Handling

Discourse uses virtual scrolling for long topics. Posts are destroyed and recreated as users scroll:

1. **Don't rely on DOM for state** - Use JavaScript Maps/Sets
2. **Re-apply modifications** - Check and restore state on each scan
3. **Use debouncing** - Avoid excessive processing during rapid scroll

```javascript
const debouncedScan = () => {
  if (scanTimeout) clearTimeout(scanTimeout);
  scanTimeout = setTimeout(scanAndAddButtons, 100);
};
```

### Page Transition Management

Clear appropriate state on page changes:

```javascript
api.onPageChange(() => {
  buttonsAdded.clear();  // Clear button tracking
  // Don't clear translationState - preserves translations
  setTimeout(setupObserver, 300);  // Re-setup observer
});
```

### Debugging

Enable debug mode in settings for console logging:

```javascript
if (settings.debug_mode) {
  console.log("[Post Translator] Debug info:", data);
}
```

Use a consistent prefix for easy filtering: `[Post Translator]`

### Error Handling

Provide user-friendly error messages:

```javascript
if (result.error === "Request timeout") {
  errorMessage = i18n(themePrefix("post_translator.error_timeout"));
} else if (result.error === "Network error") {
  errorMessage = i18n(themePrefix("post_translator.error_network"));
} else {
  errorMessage = i18n(themePrefix("post_translator.error_generic"));
}
```

### API Request Pattern

Use AbortController for timeouts:

```javascript
const controller = new AbortController();
const timeoutId = setTimeout(
  () => controller.abort(),
  settings.translation_api_timeout
);

try {
  const response = await fetch(url, {
    signal: controller.signal,
    // ... other options
  });
  clearTimeout(timeoutId);
} catch (error) {
  clearTimeout(timeoutId);
  if (error.name === "AbortError") {
    // Handle timeout
  }
}
```

## Adding New Features

### New API Initializer

Create in `javascripts/discourse/api-initializers/`:

```gjs
import { apiInitializer } from "discourse/lib/api";

export default apiInitializer("1.0.0", (api) => {
  // Your initialization code
});
```

### New Glimmer Component

Create in `javascripts/discourse/components/`:

```gjs
import Component from "@glimmer/component";

export default class MyComponent extends Component {
  <template>
    <div class="my-component">
      {{yield}}
    </div>
  </template>
}
```

### New Styles

Add to `common/common.scss` or create scheme-specific files:

- `common/common.scss` - All schemes
- `desktop/desktop.scss` - Desktop only
- `mobile/mobile.scss` - Mobile only

### New Settings

Add to `settings.yml`:

```yaml
new_setting:
  type: bool
  default: true
  description:
    en: "Description"
```

### New Locale Keys

Add to all locale files (`locales/*.yml`):

```yaml
en:
  post_translator:
    new_key: "New text"
```

## Common Discourse Selectors

| Selector | Description |
|----------|-------------|
| `.topic-post` | Single post container |
| `article[data-post-id]` | Post article with ID |
| `.cooked` | Rendered post content |
| `.post-controls .actions` | Post action buttons area |
| `#main-outlet` | Main content container |
| `.topic-area` | Topic view container |

## References

- [Discourse Theme Developer Guide](https://meta.discourse.org/t/beginners-guide-to-using-discourse-themes/91966)
- [Discourse Plugin API](https://docs.discourse.org/)
- [Ember.js Guides](https://guides.emberjs.com/)
- [Glimmer Components](https://guides.emberjs.com/release/components/)
