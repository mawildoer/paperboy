// Runs in the page when Paperboy is chosen from Safari's share sheet: hands the extension the
// page as the browser shows it, so an article behind a sign-in arrives complete.
var SharePage = function () {};
SharePage.prototype = {
  run: function (args) {
    args.completionFunction({
      url: document.URL,
      title: document.title,
      html: document.documentElement.outerHTML,
    });
  },
  finalize: function () {},
};
var ExtensionPreprocessingJS = new SharePage();
