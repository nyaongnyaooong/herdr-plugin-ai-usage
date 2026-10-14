import Darwin

@main
struct DashboardInputTests {
    static func main() throws {
        try popupKeysDoNotNeedEnterOrEchoAndRestoreTerminal()
        pipeInputIsNotPutInTerminalMode()
        print("macOS dashboard PTY tests passed")
    }
    static func popupKeysDoNotNeedEnterOrEchoAndRestoreTerminal() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        assert(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        var before = termios()
        assert(tcgetattr(slave, &before) == 0)
        let input = DashboardInput(fd: slave)
        assert(input.isInteractive)
        var during = termios()
        assert(tcgetattr(slave, &during) == 0)
        assert(during.c_lflag & tcflag_t(ICANON | ECHO | ISIG) == 0)
        assert(during.c_oflag == before.c_oflag)

        let cases: [(String, DashboardInput.Key)] = [
            ("r", .character("r")), ("q", .character("q")),
            ("\u{1b}[A", .up), ("\u{1b}[B", .down),
            ("\u{1b}OA", .up), ("\u{1b}OB", .down),
            ("\u{1b}[1;2A", .up), ("\u{1b}[1;2B", .down),
            ("\u{1b}[D", .ignored), ("\u{1b}[3~", .ignored),
            ("\r", .enter), ("\u{7f}", .backspace),
            ("\u{1b}", .escape), ("\u{3}", .quit), ("\u{4}", .quit)
        ]
        for (sequence, expected) in cases {
            let bytes = Array(sequence.utf8)
            assert(bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) } == bytes.count)
            assert(input.readKey() == expected)
        }
        var output = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        assert(poll(&output, 1, 20) == 0)
        input.restore()
        var after = termios()
        assert(tcgetattr(slave, &after) == 0)
        // macOS sets PENDIN when returning to canonical input.
        assert(after.c_lflag & ~tcflag_t(PENDIN) == before.c_lflag & ~tcflag_t(PENDIN))
        assert(after.c_iflag == before.c_iflag)
        assert(after.c_oflag == before.c_oflag)
        assert(withUnsafeBytes(of: after.c_cc) { Array($0) } == withUnsafeBytes(of: before.c_cc) { Array($0) })
    }

    static func pipeInputIsNotPutInTerminalMode() {
        var descriptors: [Int32] = [-1, -1]
        assert(pipe(&descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let input = DashboardInput(fd: descriptors[0])
        assert(!input.isInteractive)
    }
}
