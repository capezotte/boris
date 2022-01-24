Lightweight process daemon for out of memory scenarios. A reimplementation of [bustd](https://github.com/vrmiguel/bustd) in Zig.

For his own take on the bustd-in-Zig concept, check out [buztd](https://github.com/vrmiguel/buztd/).

Behavior is very similar, except in a few implementation details on how access to /proc is handled and the fact that it accepts the following command line arguments instead of a compiled-in config:

- `-r`: terminal RAM percentage, when it's supposed to act.
- `-p`: terminal PSI value. When both PSI and RAM are terminal, boris acts.
- `-s`: terminal swap percentage.
- `-u`: A series of pipe-separted glob patterns for processes that will be avoided. The entire executable will be matched. For instance, `*/sway|*/sshd`.
- `-g`: kills process groups instead of individual processes.
- `-n`: dry-run. Prints which process would be killed if running now.

