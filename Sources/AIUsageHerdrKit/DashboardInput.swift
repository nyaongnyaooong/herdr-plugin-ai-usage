import Darwin

/// Reads popup shortcuts without canonical line buffering or terminal echo.
final class DashboardInput {
    enum Key: Equatable {
        case character(String), up, down, enter, backspace, escape, quit, ignored
    }

    private let fd: Int32
    private var original: termios?
    var isInteractive: Bool { original != nil }

    init(fd: Int32 = STDIN_FILENO) {
        self.fd = fd
        var attrs = termios()
        guard isatty(fd) == 1, tcgetattr(fd, &attrs) == 0 else { return }
        let saved = attrs
        // Leave output processing intact so newlines retain their normal layout.
        attrs.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        attrs.c_iflag &= ~tcflag_t(IXON | ICRNL | INLCR | IGNCR)
        withUnsafeMutableBytes(of: &attrs.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        if tcsetattr(fd, TCSANOW, &attrs) == 0 { original = saved }
    }

    func restore() {
        guard var attrs = original else { return }
        tcsetattr(fd, TCSANOW, &attrs)
        original = nil
    }

    deinit { restore() }

    private func byte(timeout: Int32? = nil) -> UInt8? {
        if let timeout {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, timeout) > 0 else { return nil }
        }
        var value: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &value, 1)
            if count == 1 { return value }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    func readKey() -> Key? {
        guard let first = byte() else { return nil }
        switch first {
        case 3, 4: return .quit
        case 10, 13: return .enter
        case 8, 127: return .backspace
        case 27:
            guard let start = byte(timeout: 50) else { return .escape }
            guard start == 91 || start == 79 else { return .ignored }
            // Consume the entire CSI/SS3 sequence, including arrow modifiers.
            for _ in 0..<32 {
                guard let next = byte(timeout: 50) else { return .ignored }
                if next >= 64 && next <= 126 {
                    switch next {
                    case 65: return .up
                    case 66: return .down
                    default: return .ignored
                    }
                }
            }
            return .ignored
        case 32...126: return .character(String(UnicodeScalar(first)).lowercased())
        default: return .ignored
        }
    }
}
