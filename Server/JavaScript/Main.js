const RewriteJavaScript = require("./Rewriter");

const Source = `
const Meow = location.href;
console.log(Meow);
`;

console.log(RewriteJavaScript(Source));
