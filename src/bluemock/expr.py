"""Parse once, evaluate safely: no Python eval/exec or object access."""

import ast
import math
import operator
import random
from dataclasses import dataclass
from typing import Any, Mapping

from .limits import MAX_EXPONENT, MAX_INT_BITS, MAX_STRING_LENGTH


class ExpressionError(ValueError):
    """An invalid expression or a failed evaluation."""


FUNCTIONS = {"abs": abs, "round": round, "int": int, "float": float, "str": str,
             "min": min, "max": max, "len": len,
             "uniform": random.uniform, "randint": random.randint}
BINARY = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
          ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv,
          ast.Mod: operator.mod, ast.Pow: operator.pow}
COMPARE = {ast.Eq: operator.eq, ast.NotEq: operator.ne, ast.Lt: operator.lt,
           ast.LtE: operator.le, ast.Gt: operator.gt, ast.GtE: operator.ge,
           ast.In: lambda a, b: a in b, ast.NotIn: lambda a, b: a not in b,
           ast.Is: operator.is_, ast.IsNot: operator.is_not}


def _check(node):
    if isinstance(node, ast.Constant):
        if type(node.value) not in (str, int, float, bool):
            raise ExpressionError("Only number, string and boolean literals are allowed")
    elif isinstance(node, ast.Name):
        pass  # Names are resolved against the runtime scope, never Python globals.
    elif isinstance(node, ast.BinOp) and type(node.op) in BINARY:
        _check(node.left)
        _check(node.right)
        exponent = node.right
        if isinstance(exponent, ast.UnaryOp) and isinstance(exponent.op, ast.USub):
            exponent = exponent.operand
        if isinstance(node.op, ast.Pow) and isinstance(exponent, ast.Constant):
            if not isinstance(exponent.value, (int, float)) or abs(exponent.value) > MAX_EXPONENT:
                raise ExpressionError(f"Exponent magnitude must not exceed {MAX_EXPONENT}")
    elif isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.Not)):
        _check(node.operand)
    elif isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
        for value in node.values:
            _check(value)
    elif isinstance(node, ast.Compare) and all(type(op) in COMPARE for op in node.ops):
        for value in [node.left, *node.comparators]:
            _check(value)
    elif isinstance(node, ast.IfExp):
        for value in (node.test, node.body, node.orelse):
            _check(value)
    elif isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name) or node.func.id not in FUNCTIONS:
            raise ExpressionError("Calls are allowed only to: " + ", ".join(FUNCTIONS))
        if node.keywords:
            raise ExpressionError("Keyword arguments are not allowed")
        for arg in node.args:
            _check(arg)
    else:
        raise ExpressionError(f"{type(node).__name__} is not allowed")


def _evaluate(node, scope):
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        if node.id not in scope:
            raise ExpressionError(f"Unknown name: {node.id}")
        return scope[node.id]
    if isinstance(node, ast.BinOp):
        left, right = _evaluate(node.left, scope), _evaluate(node.right, scope)
        if isinstance(node.op, ast.Mod) and isinstance(left, (str, bytes)):
            raise ExpressionError("string % formatting is not supported; use a template")
        if isinstance(node.op, ast.Mult):
            sequence, count = (left, right) if isinstance(left, (str, bytes)) else (right, left)
            if isinstance(sequence, (str, bytes)) and isinstance(count, int):
                if len(sequence) * max(count, 0) > MAX_STRING_LENGTH:
                    raise ExpressionError(f"Sequence result exceeds {MAX_STRING_LENGTH} characters/bytes")
        if isinstance(node.op, ast.Add) and type(left) is type(right) and isinstance(left, (str, bytes)):
            if len(left) + len(right) > MAX_STRING_LENGTH:
                raise ExpressionError(f"Sequence result exceeds {MAX_STRING_LENGTH} characters/bytes")
        if isinstance(node.op, ast.Pow):
            if not isinstance(right, (int, float)) or abs(right) > MAX_EXPONENT:
                raise ExpressionError(f"Exponent magnitude must not exceed {MAX_EXPONENT}")
            if isinstance(left, (int, float)) and abs(left) > 1:
                if abs(right) * math.log2(abs(left)) > MAX_INT_BITS:
                    raise ExpressionError(f"Power result exceeds {MAX_INT_BITS} bits")
        result = BINARY[type(node.op)](left, right)
        if isinstance(result, int) and result.bit_length() > MAX_INT_BITS:
            raise ExpressionError(f"Integer result exceeds {MAX_INT_BITS} bits")
        if isinstance(result, (str, bytes)) and len(result) > MAX_STRING_LENGTH:
            raise ExpressionError(f"Sequence result exceeds {MAX_STRING_LENGTH} characters/bytes")
        return result
    if isinstance(node, ast.UnaryOp):
        value = _evaluate(node.operand, scope)
        return -value if isinstance(node.op, ast.USub) else not value
    if isinstance(node, ast.BoolOp):
        for child in node.values:
            value = _evaluate(child, scope)
            if isinstance(node.op, ast.And) and not value:
                return value
            if isinstance(node.op, ast.Or) and value:
                return value
        return value
    if isinstance(node, ast.Compare):
        left = _evaluate(node.left, scope)
        for op, child in zip(node.ops, node.comparators):
            right = _evaluate(child, scope)
            if not COMPARE[type(op)](left, right):
                return False
            left = right
        return True
    if isinstance(node, ast.IfExp):
        return _evaluate(node.body if _evaluate(node.test, scope) else node.orelse, scope)
    if isinstance(node, ast.Call):
        return FUNCTIONS[node.func.id](*(_evaluate(arg, scope) for arg in node.args))
    raise ExpressionError("Unsupported expression")


@dataclass(frozen=True)
class Expression:
    source: str
    tree: ast.AST

    def evaluate(self, scope: Mapping[str, Any]) -> Any:
        try:
            return _evaluate(self.tree, scope)
        except ExpressionError:
            raise
        except (ArithmeticError, TypeError, ValueError, MemoryError, RecursionError) as exc:
            raise ExpressionError(f"{self.source!r}: {exc}") from exc


def compile_expression(source) -> Expression:
    # YAML numeric scalar expressions are convenient for fixed byte segments.
    if type(source) in (int, float, bool):
        source = repr(source)
    if not isinstance(source, str):
        raise ExpressionError("Expression must be text or a numeric/boolean literal")
    source = source.strip()
    try:
        tree = ast.parse(source, mode="eval").body
        _check(tree)
    except (SyntaxError, RecursionError) as exc:
        raise ExpressionError(f"Invalid expression: {getattr(exc, 'msg', str(exc))}") from exc
    return Expression(source, tree)


def evaluate(source, scope: Mapping[str, Any]) -> Any:
    return (source if isinstance(source, Expression) else compile_expression(source)).evaluate(scope)


def expression_names(expression: Expression) -> set[str]:
    """Return scope references, excluding the whitelisted function call targets."""
    callees = {id(node.func) for node in ast.walk(expression.tree) if isinstance(node, ast.Call)}
    return {node.id for node in ast.walk(expression.tree)
            if isinstance(node, ast.Name) and id(node) not in callees}


def unknown_name_messages(names, available) -> list[str]:
    """Share deterministic scope diagnostics between expressions and templates."""
    available = set(available)
    listing = ", ".join(sorted(available)) or "(none)"
    return [f"Unknown name {name!r}; available: {listing}" for name in sorted(set(names) - available)]
