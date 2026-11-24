const Parser = require("@babel/parser");
const Traverse = require("@babel/traverse").default;
const Generate = require("@babel/generator").default;
const Types = require("@babel/types");

function RewriteJavaScript(Source) {
  const Ast = Parser.parse(Source, {
    sourceType: "unambiguous",
    plugins: ["jsx"],
  });

  Traverse(Ast, {
    MemberExpression(Path) {
      const Node = Path.node;

      if (
        (Types.isIdentifier(Node.object, { name: "window" }) ||
          Types.isIdentifier(Node.object, { name: "document" })) &&
        !Path.scope.hasBinding(Node.object.name) &&
        ((!Node.computed &&
          Types.isIdentifier(Node.property, { name: "location" })) ||
          (Node.computed &&
            Types.isStringLiteral(Node.property, { value: "location" })))
      ) {
        Path.replaceWith(
          Types.memberExpression(
            Types.identifier("__Yip"),
            Types.identifier("location"),
          ),
        );
      }
    },

    ReferencedIdentifier(Path) {
      if (
        Path.node.name === "location" &&
        !Path.scope.hasBinding("location") &&
        !Path.parentPath.isMemberExpression({
          object: Path.node,
        })
      ) {
        Path.replaceWith(
          Types.memberExpression(
            Types.identifier("__Yip"),
            Types.identifier("location"),
          ),
        );
      }
    },
  });

  return Generate(Ast).code;
}

module.exports = RewriteJavaScript;
