
import { codeToHtml } from "https://esm.sh/shiki@4.0.2";

const SHIKI_VERSION = "4.0.2";
const SHIKI_SELECTOR = 'pre[data-shiki-lang="nushell"]';
const SHIKI_THEME = "rose-pine-dawn";
const toggle = document.querySelector("[data-nav-toggle]");
const sidebar = document.querySelector(".sidebar");
const nav = document.querySelector("[data-nav]");
const search = document.querySelector("[data-nav-search]");
const searchDropdown = document.querySelector("[data-search-dropdown]");
const searchIndexNode = document.getElementById("search-index");
const commandLinks = Array.from(document.querySelectorAll("[data-command-link]"));
const sidebarScrollKey = "nu-doc-gen.sidebar-scroll-top";
const sections = commandLinks
  .map((link) => {
    const hash = link.getAttribute("href")?.split("#")[1];
    if (!hash) return null;
    const target = document.getElementById(hash);
    if (!target) return null;
    return { link, target };
  })
  .filter(Boolean);

if (toggle && nav) {
  toggle.addEventListener("click", () => {
    nav.classList.toggle("is-open");
  });
}

if (sidebar && typeof sessionStorage !== "undefined") {
  const savedScroll = Number.parseInt(sessionStorage.getItem(sidebarScrollKey) || "", 10);
  if (Number.isFinite(savedScroll)) {
    sidebar.scrollTop = savedScroll;
  }

  let scrollFrame = null;
  const persistSidebarScroll = () => {
    sessionStorage.setItem(sidebarScrollKey, String(sidebar.scrollTop));
    scrollFrame = null;
  };

  sidebar.addEventListener("scroll", () => {
    if (scrollFrame !== null) return;
    scrollFrame = window.requestAnimationFrame(persistSidebarScroll);
  });

  window.addEventListener("pagehide", persistSidebarScroll);
}

const escapeHtml = (value = "") =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll(String.fromCharCode(39), "&#39;");

const highlightText = (value, indices) => {
  if (!value) return "";
  if (!Array.isArray(indices) || indices.length === 0) return escapeHtml(value);

  let html = "";
  let cursor = 0;
  indices.forEach(([start, end]) => {
    if (start > cursor) {
      html += escapeHtml(value.slice(cursor, start));
    }
    html += `<mark>${escapeHtml(value.slice(start, end + 1))}</mark>`;
    cursor = end + 1;
  });

  if (cursor < value.length) {
    html += escapeHtml(value.slice(cursor));
  }

  return html;
};

const fallbackIndices = (value, query) => {
  const source = value.toLowerCase();
  const searchText = query.toLowerCase();
  const indices = [];
  let start = source.indexOf(searchText);

  while (start !== -1) {
    indices.push([start, start + searchText.length - 1]);
    start = source.indexOf(searchText, start + searchText.length);
  }

  return indices;
};

if (search && searchDropdown && searchIndexNode) {
  const searchIndex = JSON.parse(searchIndexNode.textContent || "[]");
  const fuse =
    typeof Fuse === "function"
      ? new Fuse(searchIndex, {
          includeMatches: true,
          threshold: 0.34,
          ignoreLocation: true,
          minMatchCharLength: 2,
          keys: [
            { name: "title", weight: 0.7 },
            { name: "category", weight: 0.2 },
            { name: "file", weight: 0.05 },
            { name: "summary", weight: 0.05 },
          ],
        })
      : null;

  let selectedIndex = -1;

  const getResults = (query) => {
    if (!query) return [];

    if (fuse) {
      return fuse.search(query, { limit: 8 });
    }

    return searchIndex
      .filter((item) => {
        const haystack = `${item.title} ${item.category} ${item.file} ${item.summary}`.toLowerCase();
        return haystack.includes(query.toLowerCase());
      })
      .slice(0, 8)
      .map((item) => ({
        item,
        matches: [
          { key: "title", indices: fallbackIndices(item.title, query) },
          { key: "category", indices: fallbackIndices(item.category, query) },
        ],
      }));
  };

  const getMatchIndices = (matches, key) =>
    matches?.find((entry) => entry.key === key)?.indices || [];

  const closeDropdown = () => {
    searchDropdown.hidden = true;
    searchDropdown.innerHTML = "";
    selectedIndex = -1;
  };

  const updateSelection = () => {
    const links = Array.from(searchDropdown.querySelectorAll(".search-result"));
    links.forEach((link, index) => {
      link.classList.toggle("is-selected", index === selectedIndex);
    });
  };

  const renderResults = (query) => {
    const results = getResults(query);

    if (results.length === 0) {
      searchDropdown.hidden = false;
      searchDropdown.innerHTML = `<div class="search-empty">No matches for <strong>${escapeHtml(query)}</strong>.</div>`;
      selectedIndex = -1;
      return;
    }

    searchDropdown.hidden = false;
    searchDropdown.innerHTML = results
      .map(({ item, matches }) => {
        const title = highlightText(item.title, getMatchIndices(matches, "title"));
        const category = highlightText(
          item.category,
          getMatchIndices(matches, "category").length > 0
            ? getMatchIndices(matches, "category")
            : fallbackIndices(item.category, query)
        );
        const file = highlightText(item.file, getMatchIndices(matches, "file"));

        return `
          <a class="search-result" href="${escapeHtml(item.url)}">
            <span class="search-result-kind">${escapeHtml(item.kind)}</span>
            <span class="search-result-title">${title}</span>
            <span class="search-result-meta">${category} · ${file}</span>
          </a>
        `;
      })
      .join("");

    selectedIndex = 0;
    updateSelection();
  };

  search.addEventListener("input", (event) => {
    const query = event.target.value.trim();

    if (query === "") {
      closeDropdown();
      return;
    }

    renderResults(query);
  });

  search.addEventListener("focus", () => {
    const query = search.value.trim();
    if (query !== "") {
      renderResults(query);
    }
  });

  search.addEventListener("keydown", (event) => {
    const links = Array.from(searchDropdown.querySelectorAll(".search-result"));
    if (searchDropdown.hidden || links.length === 0) return;

    if (event.key === "ArrowDown") {
      event.preventDefault();
      selectedIndex = (selectedIndex + 1) % links.length;
      updateSelection();
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      selectedIndex = (selectedIndex - 1 + links.length) % links.length;
      updateSelection();
      return;
    }

    if (event.key === "Enter" && selectedIndex >= 0) {
      event.preventDefault();
      links[selectedIndex].click();
      return;
    }

    if (event.key === "Escape") {
      closeDropdown();
      search.blur();
    }
  });

  document.addEventListener("click", (event) => {
    if (!event.target.closest(".nav-search-wrap")) {
      closeDropdown();
    }
  });
}

if (sections.length > 0) {
  const observer = new IntersectionObserver(
    (entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];

      if (!visible) return;

      sections.forEach(({ link, target }) => {
        link.classList.toggle("is-active", target === visible.target);
      });
    },
    {
      rootMargin: "0px 0px -70% 0px",
      threshold: [0, 1],
    }
  );

  sections.forEach(({ target }) => observer.observe(target));
}

const highlightNushellBlocks = async () => {
  const blocks = Array.from(document.querySelectorAll(SHIKI_SELECTOR));
  if (blocks.length === 0) return;

  await Promise.all(
    blocks.map(async (block) => {
      if (block.dataset.shikiRendered === "true") return;

      const source = block.querySelector('code[data-shiki-source="nushell"]');
      if (!source) return;

      const code = source.textContent ?? "";
      let html;
      try {
        html = await codeToHtml(code, {
          lang: "nushell",
          theme: SHIKI_THEME,
        });
      } catch (error) {
        console.error(`Failed to highlight Nushell block with Shiki ${SHIKI_VERSION}`, error);
        return;
      }

      const template = document.createElement("template");
      template.innerHTML = html.trim();
      const pre = template.content.querySelector("pre");
      if (!pre) return;

      block.replaceWith(pre);
      block.dataset.shikiRendered = "true";
    })
  );
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    void highlightNushellBlocks();
  }, { once: true });
} else {
  void highlightNushellBlocks();
}
