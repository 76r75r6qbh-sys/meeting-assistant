(() => {
  const messageHandler = window.webkit?.messageHandlers?.casablancaViewer;
  const post = (type) => {
    messageHandler?.postMessage({ type });
  };

  const viewer = toastui.Editor.factory({
    el: document.querySelector('#viewer'),
    viewer: true,
    initialValue: '',
    usageStatistics: false
  });

  window.CasablancaViewer = {
    setMarkdown(markdown) {
      viewer.setMarkdown(markdown ?? '');
    }
  };

  post('ready');
})();
