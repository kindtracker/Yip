const Parser = require("@babel/parser");
const Traverse = require("@babel/traverse").default;
const Generate = require("@babel/generator").default;
const Types = require("@babel/types");

function RewriteWindowApi(Path, Name) {
  const IsDirectReference =
    Path.isIdentifier({ name: Name }) && !Path.scope.hasBinding(Name);
  const IsWindowReference =
    Path.parentPath.isMemberExpression() &&
    Path.parentPath.node.object.type === "Identifier" &&
    Path.parentPath.node.object.name === "window" &&
    Path.parentPath.node.property.name === Name;
  if (!IsDirectReference && !IsWindowReference) {
    return;
  }

  const FunctionCall = Types.callExpression(
    Types.memberExpression(
      Types.identifier("window"),
      Types.identifier("__YipGetWindowApi"),
    ),
    [Types.stringLiteral(Name)],
  );
  if (IsWindowReference) {
    Path.parentPath.replaceWith(FunctionCall);
  } else {
    Path.replaceWith(FunctionCall);
  }
}

function RewriteJavaScript(Source) {
  const Ast = Parser.parse(Source, {
    sourceType: "unambiguous",
  });

  Traverse(Ast, {
    ReferencedIdentifier(Path) {
      RewriteWindowApi(Path, "location");
    },
  });

  return Generate(Ast).code;
}

module.exports = RewriteJavaScript;
