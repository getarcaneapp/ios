# TreeSitterYAML

Grammar sources from https://github.com/tree-sitter-grammars/tree-sitter-yaml, tag v0.7.2, under the included MIT license. Sources are unmodified.

This local Swift package explicitly compiles both parser.c and scanner.c. The upstream 0.7.2 manifest checks for scanner.c relative to the working directory, which can omit the scanner under Xcode/SwiftPM and fail at link time. Keep the explicit source list when updating these vendored sources.
