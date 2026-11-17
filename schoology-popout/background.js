// Opens a launch URL in a large standalone popup window (no tabs/address bar clutter).
chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg?.type !== "sgy-popout-window" || !msg.url) return;
  chrome.windows.getCurrent((cur) => {
    const width = Math.round((cur?.width || 1400) * 0.9);
    const height = Math.round((cur?.height || 900) * 0.9);
    chrome.windows.create({
      url: msg.url,
      type: "popup",
      width,
      height,
      left: (cur?.left || 0) + Math.round(((cur?.width || width) - width) / 2),
      top: (cur?.top || 0) + Math.round(((cur?.height || height) - height) / 2),
      focused: true
    });
  });
});

// Toolbar icon: pop out the first embed on the current Schoology page.
chrome.action.onClicked.addListener((tab) => {
  if (!tab.id) return;
  chrome.tabs.sendMessage(tab.id, { type: "sgy-popout-first" }).catch(() => {});
});
