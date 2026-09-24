{ lib }:

let
  inherit (builtins)
    concatStringsSep
    elemAt
    foldl'
    fromJSON
    head
    isList
    length
    listToAttrs
    match
    split
    stringLength
    substring
    ;
  inherit (lib)
    hasPrefix
    hasSuffix
    nameValuePair
    removePrefix
    reverseList
    splitString
    ;
  trim = lib.strings.trim;
  drop = count: text: substring count (stringLength text) text;
  ignored = text: match "[ ]*(#.*)?" text != null;
  uncomment = text: trim (head (split "[ ]+#" text));
  unicode =
    digits:
    let
      code = lib.fromHexString digits;
      hex = value: lib.fixedWidthString 4 "0" (lib.toHexString value);
      escaped =
        if code < 65536 then
          "\\u${hex code}"
        else
          "\\u${hex (55296 + builtins.div (code - 65536) 1024)}\\u${
            hex (56320 + lib.mod (code - 65536) 1024)
          }";
    in
    fromJSON "\"${escaped}\"";
  escapes = {
    "0" = unicode "0000";
    a = unicode "0007";
    b = unicode "0008";
    t = "\t";
    n = "\n";
    v = unicode "000b";
    f = unicode "000c";
    r = "\r";
    e = unicode "001b";
    " " = " ";
    "\"" = "\"";
    "/" = "/";
    "\\" = "\\";
    N = unicode "0085";
    "_" = unicode "00a0";
    L = unicode "2028";
    P = unicode "2029";
  };
  unescape =
    text:
    lib.concatMapStrings (
      part:
      if !isList part then
        part
      else
        let
          escape = head part;
        in
        if match "[xuU].*" escape != null then unicode (drop 1 escape) else escapes.${escape}
    ) (split ''\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)'' text);
  quoted =
    text:
    let
      single = match "'(([^']|'')*)'(.*)" text;
      double = match ''"(([^"\\[:cntrl:]]|\\.)*)"(.*)'' text;
    in
    if single != null then
      {
        value = builtins.replaceStrings [ "''" ] [ "'" ] (head single);
        rest = elemAt single 2;
      }
    else
      {
        value = unescape (head double);
        rest = elemAt double 2;
      };
  scalar =
    text:
    let
      value = uncomment text;
      number = match "-?(0|[1-9][0-9]*)(\\.[0-9]*)?([eE][+-]?[0-9]+)?" value;
    in
    if value == "" then
      null
    else if
      number != null
      || builtins.elem value [
        "null"
        "true"
        "false"
      ]
    then
      fromJSON (builtins.replaceStrings [ ".e" ".E" ] [ ".0e" ".0E" ] value)
    else
      value;
  keyValue =
    text:
    let
      isQuoted = hasPrefix "'" text || hasPrefix "\"" text;
      key = quoted text;
      plain = match "(([^:]|:[^[:space:]])+):([ ].*|$)" text;
      quotedValue = match "[ ]*:[ ]*(.*)" key.rest;
    in
    if isQuoted && quotedValue != null then
      {
        name = key.value;
        value = head quotedValue;
      }
    else if !isQuoted && !hasPrefix "[" text && !hasPrefix "{" text && plain != null then
      {
        name = trim (head plain);
        value = trim (elemAt plain 2);
      }
    else
      null;

  # Inline recursion consumes one value and returns the unconsumed suffix. This
  # keeps commas and colons inside quoted strings and nested collections intact.
  inline =
    text:
    let
      input = trim text;
      collection =
        close: make: field:
        let
          loop =
            rest: values:
            let
              next = trim rest;
              item = field next;
              suffix = trim item.rest;
            in
            if hasPrefix close next then
              {
                value = make (reverseList values);
                rest = drop 1 next;
              }
            else if hasPrefix "," suffix then
              loop (drop 1 suffix) ([ item.value ] ++ values)
            else
              {
                value = make (reverseList ([ item.value ] ++ values));
                rest = drop 1 suffix;
              };
        in
        loop (drop 1 input) [ ];
      field =
        input:
        let
          isQuoted = hasPrefix "'" input || hasPrefix "\"" input;
          key = quoted input;
          pair = match "(([^][{}:,]|:[^][{},[:space:]])+):([ ].*|$)" input;
          remainder = if isQuoted then trim key.rest else elemAt pair 2;
          name = if isQuoted then key.value else trim (head pair);
          value = inline (if isQuoted then removePrefix ":" remainder else remainder);
        in
        {
          value = nameValuePair name value.value;
          rest = value.rest;
        };
      plain = match "([^][{},]*)(.*)" input;
    in
    if hasPrefix "{" input then
      collection "}" listToAttrs field
    else if hasPrefix "[" input then
      collection "]" (x: x) inline
    else if hasPrefix "'" input || hasPrefix "\"" input then
      quoted input
    else
      {
        value = scalar (head plain);
        rest = elemAt plain 1;
      };
  completeInline =
    text:
    if
      !lib.any (prefix: hasPrefix prefix text) [
        "{"
        "["
        "'"
        "\""
      ]
    then
      scalar text
    else
      (inline text).value;

  lines =
    text:
    let
      parts = splitString "\n" text;
      count = length parts;
    in
    lib.imap0 (
      index: raw:
      let
        parts = match "([ ]*)(.*)" raw;
      in
      {
        inherit raw;
        indent = stringLength (head parts);
        body = elemAt parts 1;
        newline = index < count - 1;
      }
    ) (if hasSuffix "\n" text then lib.take (count - 1) parts else parts);
  groups =
    indentation: input:
    let
      finish = entry: entry // { children = reverseList entry.children; };
      state =
        foldl'
          (
            state: line:
            if !ignored line.raw && line.indent == indentation then
              {
                done = lib.optional (state.current != null) (finish state.current) ++ state.done;
                current = line // {
                  children = [ ];
                };
              }
            else if state.current == null then
              state
            else
              state
              // {
                current = state.current // {
                  children = [ line ] ++ state.current.children;
                };
              }
          )
          {
            done = [ ];
            current = null;
          }
          input;
    in
    reverseList (lib.optional (state.current != null) (finish state.current) ++ state.done);
  literal =
    parent: header: children:
    let
      indicator = match "\\|([1-9]?)([-+]?)([1-9]?)([ ]+#.*)?" header;
      contentLength = lib.lists.findFirstIndex (
        line: line.indent <= parent && trim line.raw != ""
      ) (length children) children;
      contentLines = lib.take contentLength children;
      first = lib.findFirst (line: trim line.raw != "") null contentLines;
      digit = elemAt indicator 0 + elemAt indicator 2;
      indentation =
        if digit != "" then
          parent + fromJSON digit
        else if first == null then
          foldl' (indent: line: lib.max indent line.indent) (parent + 1) contentLines
        else
          first.indent;
      content = lib.concatMapStrings (
        line: drop indentation line.raw + lib.optionalString line.newline "\n"
      ) contentLines;
      stripped = head (match "([^\n]*(\n+[^\n]+)*)\n*" content);
      chomp = elemAt indicator 1;
    in
    if chomp == "+" then
      content
    else if chomp == "-" then
      stripped
    else
      stripped + lib.optionalString (stripped != "" && hasSuffix "\n" content) "\n";
  value =
    parent: compact: body: children:
    let
      text = trim body;
      pair = keyValue text;
    in
    if ignored text then
      block children
    else if hasPrefix "|" text then
      literal parent text children
    else if compact && (pair != null || text == "-" || hasPrefix "- " text) then
      block (
        [
          {
            raw = text;
            body = text;
            indent = parent + 2;
            newline = true;
          }
        ]
        ++ children
      )
    else
      completeInline text;
  block =
    input:
    let
      first = lib.findFirst (line: !ignored line.raw) null input;
      indentation = first.indent;
      entries = groups indentation input;
      sequence = entry: entry.body == "-" || hasPrefix "- " entry.body;
      pairs =
        foldl'
          (
            state: entry:
            if state.pending == null && hasPrefix "? " entry.body then
              state // { pending = completeInline (trim (drop 2 entry.body)); }
            else
              let
                explicit = state.pending != null;
                pair =
                  if explicit then
                    {
                      name = state.pending;
                      value = trim (drop 1 entry.body);
                    }
                  else
                    keyValue entry.body;
              in
              {
                pending = null;
                values = [
                  (nameValuePair pair.name (value indentation explicit pair.value entry.children))
                ]
                ++ state.values;
              }
          )
          {
            pending = null;
            values = [ ];
          }
          entries;
    in
    if first == null then
      null
    else if sequence (head entries) then
      map (entry: value indentation true (trim (drop 1 entry.body)) entry.children) entries
    else if keyValue (head entries).body != null || hasPrefix "? " (head entries).body then
      listToAttrs pairs.values
    else
      value indentation false (head entries).body (head entries).children;

  splitDocuments =
    text:
    let
      normalized = builtins.replaceStrings [ "\r\n" ] [ "\n" ] (removePrefix "﻿" text);
      finish = state: concatStringsSep "\n" (reverseList state.current);
      state =
        foldl'
          (
            state: line:
            if match "---([ ]+#.*)?[ ]*" line != null then
              {
                documents =
                  state.documents
                  ++ lib.optional (!state.directive && (state.started || state.content)) (finish state + "\n");
                current = if state.directive then [ line ] ++ state.current else [ ];
                started = true;
                content = false;
                directive = false;
              }
            else if match "\\.\\.\\.([ ]+#.*)?[ ]*" line != null then
              {
                documents = state.documents ++ [ (finish state + "\n") ];
                current = [ ];
                started = false;
                content = false;
                directive = false;
              }
            else if hasPrefix "%" line && !state.content && !state.started then
              state
              // {
                current = [ line ] ++ state.current;
                directive = true;
              }
            else
              state
              // {
                current = [ line ] ++ state.current;
                content = state.content || !ignored line;
              }
          )
          {
            documents = [ ];
            current = [ ];
            started = false;
            content = false;
            directive = false;
          }
          (splitString "\n" normalized);
    in
    state.documents
    ++ lib.optional (state.started || state.content || state.directive || state.documents == [ ]) (
      finish state
    );
in
{
  inherit splitDocuments;
  parseDocuments = text: map (document: block (lines document)) (splitDocuments text);
}
