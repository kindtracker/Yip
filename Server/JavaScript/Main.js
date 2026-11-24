const RewriteJavaScript = require("./Rewriter");

const Source = `
window.open("meow://www.google.com");
console.log(atob(new Int16Array(4)));
`;

console.log(RewriteJavaScript(Source));
