import Foundation
import Darwin

/// Projects Desktop JSON as it arrives, without buffering discarded tool logs.
/// Foundation subsequently validates the retained JSON before it is consumed.
final class NativeAttentionJSON {
    private typealias Shape = NativeAttentionSnapshot.Shape
    private enum Phase { case key, colon, value, separator }
    private struct Container {
        var shape: Shape?
        var object: Bool
        var phase: Phase
        var key = Data()
        var child: Shape?
        var index = 0
        var emitted = false
        var canEnd = true
    }
    private var stack: [Container] = []
    private var rootStarted = false
    private var complete = false
    private var string = false
    private var escaped = false
    private var keyString = false
    private var tokenRetained = false
    private var atom = false
    private var token = Data()
    private(set) var data = Data()
    private let retainedLimit: Int
    struct InvalidJSON: Error {}

    init(retainedLimit: Int = 64 * 1024 * 1024) { self.retainedLimit = retainedLimit }

    func consume(_ input: Data) throws {
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Void in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < raw.count {
                let byte = bytes[offset]
                if string {
                    if escaped {
                        if tokenRetained { try appendToken(Data([byte])) }
                        escaped = false; offset += 1
                        continue
                    }
                    // Scan discarded strings in C, including escapes that cross
                    // read boundaries, without allocating their contents.
                    let remaining = raw.count - offset
                    let base = raw.baseAddress!
                    let quote = memchr(base + offset, 34, remaining).map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                    let slash = memchr(base + offset, 92, remaining).map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                    let end = min(quote, slash)
                    if tokenRetained { try appendToken(Data(bytes: bytes + offset, count: end - offset)) }
                    offset = end
                    if offset == raw.count { continue }
                    if tokenRetained { try appendToken(Data([bytes[offset]])) }
                    if bytes[offset] == 92 { escaped = true }
                    else { try finishString() }
                    offset += 1
                    continue
                }
                if atom {
                    if [UInt8(32), 9, 10, 13, 44, 93, 125].contains(byte) {
                        if tokenRetained { try appendOutput(token) }
                        atom = false; token.removeAll(keepingCapacity: true)
                        try finishValue()
                        continue
                    }
                    if tokenRetained { try appendToken(Data([byte])) }
                    offset += 1
                    continue
                }
                if [UInt8(32), 9, 10, 13].contains(byte) { offset += 1; continue }
                if byte == 125 || byte == 93 {
                    guard let container = stack.last, container.object == (byte == 125),
                          container.phase == .separator || container.canEnd else { throw InvalidJSON() }
                    if container.shape != nil { try appendOutput(Data([byte])) }
                    stack.removeLast()
                    try finishValue()
                } else if byte == 44 {
                    guard !stack.isEmpty, stack[stack.count - 1].phase == .separator else { throw InvalidJSON() }
                    stack[stack.count - 1].phase = stack.last!.object ? .key : .value
                    stack[stack.count - 1].canEnd = false
                } else if byte == 58 {
                    guard !stack.isEmpty, stack.last!.object, stack.last!.phase == .colon else { throw InvalidJSON() }
                    stack[stack.count - 1].phase = .value
                } else if byte == 34, stack.last?.object == true, stack.last?.phase == .key {
                    string = true; keyString = true
                    tokenRetained = stack.last?.shape != nil
                    token = tokenRetained ? Data([34]) : Data()
                } else {
                    let shape = try beginValue()
                    if byte == 123 || byte == 91 {
                        if shape != nil { try appendOutput(Data([byte])) }
                        guard stack.count < 256 else { throw InvalidJSON() }
                        stack.append(Container(shape: shape, object: byte == 123, phase: byte == 123 ? .key : .value))
                    } else {
                        // Non-leaf scalar values project to null, preserving
                        // array positions just like NativeAttentionSnapshot.
                        tokenRetained = shape == .leaf
                        if shape != nil && !tokenRetained { try appendOutput(Data("null".utf8)) }
                        token = tokenRetained ? Data([byte]) : Data()
                        if byte == 34 { string = true; keyString = false }
                        else {
                            guard byte == 45 || (48...57).contains(byte) || [UInt8(116), 102, 110].contains(byte) else { throw InvalidJSON() }
                            atom = true
                        }
                    }
                }
                offset += 1
            }
        }
    }

    func finish() throws -> Data {
        guard complete, stack.isEmpty, !string, !atom else { throw InvalidJSON() }
        return data
    }

    private func beginValue() throws -> Shape? {
        if stack.isEmpty {
            guard !rootStarted, !complete else { throw InvalidJSON() }
            rootStarted = true
            return .wire
        }
        let index = stack.count - 1
        guard stack[index].phase == .value else { throw InvalidJSON() }
        let shape = stack[index].object ? stack[index].child : stack[index].shape?.child(String(stack[index].index))
        if shape != nil {
            if stack[index].emitted { try appendOutput(Data([44])) }
            if stack[index].object {
                try appendOutput(stack[index].key)
                try appendOutput(Data([58]))
            }
            stack[index].emitted = true
        }
        return shape
    }

    private func finishString() throws {
        string = false
        if keyString {
            guard !stack.isEmpty else { throw InvalidJSON() }
            let index = stack.count - 1
            if tokenRetained {
                guard let key = try JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String else { throw InvalidJSON() }
                stack[index].key = token
                stack[index].child = stack[index].shape?.child(key)
            } else { stack[index].child = nil }
            stack[index].phase = .colon
            stack[index].canEnd = false
        } else {
            if tokenRetained { try appendOutput(token) }
            try finishValue()
        }
        token.removeAll(keepingCapacity: true)
    }

    private func finishValue() throws {
        if stack.isEmpty { complete = true; return }
        let index = stack.count - 1
        guard stack[index].phase == .value else { throw InvalidJSON() }
        stack[index].phase = .separator
        stack[index].canEnd = true
        stack[index].index += 1
    }

    private func appendToken(_ bytes: Data) throws {
        guard token.count + bytes.count <= (keyString ? 4096 : retainedLimit),
              data.count + token.count + bytes.count <= retainedLimit else { throw InvalidJSON() }
        token.append(bytes)
    }

    private func appendOutput(_ bytes: Data) throws {
        guard data.count + bytes.count <= retainedLimit else { throw InvalidJSON() }
        data.append(bytes)
    }
}
