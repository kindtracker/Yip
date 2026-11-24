const Parser = require("@babel/parser");
const Traverse = require("@babel/traverse").default;
const Generate = require("@babel/generator").default;
const Types = require("@babel/types");

function RewriteJavaScript(Source) {
  const Ast = Parser.parse(Source, {
    sourceType: "unambiguous",
  });

  Traverse(Ast, {
    ReferencedIdentifier(Path) {
      if (Path.node.name !== "location") {
        return;
      }

      if (Path.scope.hasBinding("location")) {
        return;
      }

      Path.replaceWith(
        Types.memberExpression(
          Types.identifier("__Yip"),
          Types.identifier("location"),
        ),
      );
    },

    MemberExpression(Path) {
      const Node = Path.node;

      if (
        !Node.computed &&
        Types.isIdentifier(Node.object, { name: "window" }) &&
        Types.isIdentifier(Node.property, { name: "location" })
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
