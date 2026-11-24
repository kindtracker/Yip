const RewriteJavaScript = require("./Rewriter");

const Source = `
const Meow = window.location.href;
console.log(Meow);
`;

console.log(RewriteJavaScript(Source));
