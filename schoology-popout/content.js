(() => {
  // Schoology LTI embeds look like:
  // <iframe id="external-tool-iframe" src="/external_tool/<id>/launch/iframe?">
  // Re-requesting that same /launch/iframe URL top-level makes Schoology regenerate
  // the signed LTI launch (iframe presentation target) with your session cookies,
  // so the tool signs you in exactly as it does inside the embed.
  const SELECTOR = 'iframe#external-tool-iframe, iframe[src*="/external_tool/"]';
  const DONE = "sgyPopoutDone";

  const launchUrl = (iframe) => {
    const raw = iframe.getAttribute("src");
    if (!raw || raw === "about:blank") return null;
    return new URL(raw, location.href).href;
  };

  const openWindow = (iframe) => {
    const url = launchUrl(iframe);
    if (url) chrome.runtime.sendMessage({ type: "sgy-popout-window", url });
  };

  const openTab = (iframe) => {
    const url = launchUrl(iframe);
    if (url) window.open(url, "_blank");
  };

  // In-page maximize: keeps the tool genuinely inside Schoology's iframe
  // (no reload, same window.parent), for tools that insist on being framed.
  const toggleMax = (iframe, bar, btn) => {
    const on = !iframe.classList.contains("sgy-popout-max");
    iframe.classList.toggle("sgy-popout-max", on);
    bar.classList.toggle("sgy-popout-bar-max", on);
    document.documentElement.classList.toggle("sgy-popout-noscroll", on);
    btn.textContent = on ? "✕ Restore (Esc)" : "⛶ Maximize";
  };

  const makeBtn = (label, title, fn) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "sgy-popout-btn";
    b.textContent = label;
    b.title = title;
    b.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); fn(b); });
    return b;
  };

  const attach = (iframe) => {
    if (iframe.dataset[DONE]) return;
    iframe.dataset[DONE] = "1";

    const bar = document.createElement("div");
    bar.className = "sgy-popout-bar";
    bar.append(
      makeBtn("⤢ Pop out", "Open in its own window", () => openWindow(iframe)),
      makeBtn("↗ New tab", "Open in a new tab", () => openTab(iframe)),
      makeBtn("⛶ Maximize", "Fill this page with the embed (stays framed)", (b) => toggleMax(iframe, bar, b))
    );
    iframe.parentNode.insertBefore(bar, iframe);
  };

  const scan = () => document.querySelectorAll(SELECTOR).forEach(attach);
  scan();
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const f = document.querySelector("iframe.sgy-popout-max");
    if (!f) return;
    const bar = f.previousElementSibling;
    const btn = bar?.querySelectorAll(".sgy-popout-btn")[2];
    if (bar && btn) toggleMax(f, bar, btn);
  });

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type !== "sgy-popout-first") return;
    const f = document.querySelector(SELECTOR);
    if (f) openWindow(f);
    else alert("Schoology Pop-Out: no embedded tool found on this page.");
  });
})();
