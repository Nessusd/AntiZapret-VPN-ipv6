# Читает только литеральные присваивания: shell-код никогда не исполняется.
import re
from typing import NamedTuple

_ASSIGNMENT = re.compile(r"^(?P<prefix>[ \t]*(?:export[ \t]+)?)(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<body>.*)$")


class ShellAssignment(NamedTuple):
    key: str
    value: str | None
    comment: str
    prefix: str


def parse_shell_assignment(line):
    match = _ASSIGNMENT.fullmatch(line.rstrip("\r\n"))
    if match is None:
        return None
    body = match["body"]
    value = []
    quote = None
    ended = False
    literal = True
    comment = ""
    index = 0
    while index < len(body):
        char = body[index]
        if quote == "'":
            if char == "'":
                quote = None
            else:
                value.append(char)
        elif char == "\\":
            if quote is None and ended:
                literal = False
            if index + 1 == len(body):
                literal = False
                break
            following = body[index + 1]
            if quote == '"' and following not in '\\"$`':
                value.append(char)
            value.append(following)
            index += 1
        elif quote == '"':
            if char == '"':
                quote = None
            else:
                if char in "$`":
                    literal = False
                value.append(char)
        elif char in " \t":
            ended = True
        elif char == "#" and (ended or index == 0):
            comment = body[index:]
            break
        elif ended:
            literal = False
            index += 1
            continue
        elif char in "'\"":
            quote = char
        else:
            if char in "$`;|&()<>":
                literal = False
            value.append(char)
        index += 1

    if quote is not None:
        literal = False
    return ShellAssignment(match["key"], "".join(value) if literal else None, comment, match["prefix"])


def read_shell_assignments(content):
    values = {}
    for line in content.splitlines():
        assignment = parse_shell_assignment(line)
        if assignment is not None:
            # Повторное присваивание заменяет первое, как при source setup.
            values[assignment.key] = assignment.value
    return values
