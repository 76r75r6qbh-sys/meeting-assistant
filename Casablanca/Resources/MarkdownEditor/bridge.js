(() => {
  const messageHandler = window.webkit?.messageHandlers?.casablancaEditor;
  const post = (type, payload = {}) => {
    messageHandler?.postMessage({ type, ...payload });
  };

  let editor;
  let suppressChange = false;

  const createEditor = () => {
    editor = new toastui.Editor({
      el: document.querySelector('#editor'),
      height: '100%',
      initialEditType: 'wysiwyg',
      previewStyle: 'tab',
      usageStatistics: false,
      toolbarItems: [
        ['heading', 'bold', 'italic', 'strike'],
        ['ul', 'ol', 'quote'],
        ['code', 'codeblock']
      ]
    });

    editor.on('change', () => {
      if (suppressChange) {
        return;
      }

      post('contentChanged', { markdown: editor.getMarkdown() });
    });

    post('ready');
  };

  window.CasablancaEditor = {
    focus() {
      editor?.focus();
    },

    getMarkdown() {
      return editor ? editor.getMarkdown() : '';
    },

    setEditable(isEditable) {
      document.body.dataset.editable = isEditable ? 'true' : 'false';
    },

    setMarkdown(markdown) {
      if (!editor) {
        return;
      }

      const nextValue = markdown ?? '';
      if (editor.getMarkdown() === nextValue) {
        return;
      }

      suppressChange = true;
      editor.setMarkdown(nextValue, false);
      queueMicrotask(() => {
        suppressChange = false;
      });
    },

    setPlaceholder(placeholder) {
      editor?.setPlaceholder(placeholder ?? '');
    }
  };

  createEditor();
})();
