//
//  RespringAsset.swift
//  worsegestalt
//
//  Embeds the NeoSpring respring payload (from the MIT-licensed KAMUI engine)
//  and materialises it into Documents so BQ.respring() can find it.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum RespringAsset {
    // Base64 of respring.html — the canonical NeoSpring payload
    // (https://jailbreak.party/respring, credit @neonmodder123, @skadz108).
    // NOTE: keep `allow-same-origin` in the iframe sandbox — the payload
    // depends on it (navigator.share from a same-origin srcdoc frame).
    private static let b64 = """
            PCFET0NUWVBFIGh0bWw+CjxodG1sPgogICAgPGhlYWQ+CiAgICAgICAgPHRpdGxlPnJlc3ByaW5n
            PC90aXRsZT4KICAgICAgICA8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iaW5zdGFu
            dCByZXNwcmluZyBmb3IgaU9TIGRldmljZXMiLz4KICAgICAgICA8bWV0YSBjaGFyc2V0PSJ1dGYt
            OCI+CiAgICAgICAgPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13
            aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgogICAgICAgIDxtZXRhIHByb3BlcnR5PSJvZzp0aXRs
            ZSIgY29udGVudD0icmVzcHJpbmciPgogICAgICAgIDxtZXRhIHByb3BlcnR5PSJvZzpkZXNjcmlw
            dGlvbiIgY29udGVudD0iaW5zdGFudCByZXNwcmluZyBmb3IgaU9TIGRldmljZXMiPgogICAgICAg
            IDxtZXRhIHByb3BlcnR5PSJvZzp1cmwiIGNvbnRlbnQ9Imh0dHBzOi8vamFpbGJyZWFrLnBhcnR5
            L3Jlc3ByaW5nIj4KICAgICAgICA8bWV0YSBuYW1lPSJ0aGVtZS1jb2xvciIgY29udGVudD0iIzAw
            NzRmYiI+CiAgICA8L2hlYWQ+CiAgICA8Ym9keT4KICAgICAgICA8IS0tICBiaWcgY3JlZGl0IHRv
            IEBuZW9ubW9kZGVyMTIzICAtLT4KICAgICAgICA8aWZyYW1lIGlkPSJmcmFtZSIgc3R5bGU9Indp
            ZHRoOiAxcHg7aGVpZ2h0OiAxcHg7IiBzcmNkb2M9IiIgc2FuZGJveD0iYWxsb3ctZm9ybXMgYWxs
            b3ctbW9kYWxzIGFsbG93LXNjcmlwdHMgYWxsb3ctc2FtZS1vcmlnaW4iPjwvaWZyYW1lPgogICAg
            ICAgIDxzY3JpcHQ+CiAgICAgICAgICAgIGNvbnN0IGZyYW1lID0gZG9jdW1lbnQuZ2V0RWxlbWVu
            dEJ5SWQoJ2ZyYW1lJyk7CiAgICAgICAgICAgIGNvbnN0IHJlc3ByaW5nU2NyaXB0ID0gYAogICAg
            ICAgICAgICAgICAgPGh0bWw+CiAgICAgICAgICAgICAgICA8Ym9keT4KICAgICAgICAgICAgICAg
            ICAgICA8c2NyaXB0PgogICAgICAgICAgICAgICAgICAgICAgICBjb25zdCBjb250YWluZXIgPSBk
            b2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgICAgICAgICAgICAgY29u
            dGFpbmVyLnN0eWxlLmNzc1RleHQgPSAncGVyc3BlY3RpdmU6IDFweDsgcGVyc3BlY3RpdmUtb3Jp
            Z2luOiA5OTk5OTk5JSA5OTk5OTk5JTsnOwogICAgICAgICAgICAgICAgICAgICAgICBkb2N1bWVu
            dC5ib2R5LmFwcGVuZENoaWxkKGNvbnRhaW5lcik7CiAgICAKICAgICAgICAgICAgICAgICAgICAg
            ICAgZm9yIChsZXQgaSA9IDA7IGkgPCA1MDA7IGkrKykgewogICAgICAgICAgICAgICAgICAgICAg
            ICAgICAgbGV0IGQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
            ICAgICAgICAgICAgICAgIGQuc3R5bGUuY3NzVGV4dCA9ICdwb3NpdGlvbjogYWJzb2x1dGU7IHdp
            ZHRoOiAxMDB2dzsgaGVpZ2h0OiAxMDB2aDsgYmFja2Ryb3AtZmlsdGVyOiBibHVyKDEwMHB4KTsg
            LXdlYmtpdC1iYWNrZHJvcC1maWx0ZXI6IGJsdXIoMTAwcHgpOyB0cmFuc2Zvcm06IHRyYW5zbGF0
            ZTNkKDEwMDAwMHB4LCAxMDAwMDBweCwgJyArIGkgKyAncHgpIHJvdGF0ZVkoOTBkZWcpOyc7CiAg
            ICAgICAgICAgICAgICAgICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoZCk7CiAgICAg
            ICAgICAgICAgICAgICAgICAgIH0KICAgIAogICAgICAgICAgICAgICAgICAgICAgICBzZXRJbnRl
            cnZhbCgoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBuYXZpZ2F0b3Iuc2hhcmUo
            eyB0aXRsZTogJ1InLCB0ZXh0OiAnUicucmVwZWF0KDEwMDAwMCkgfSkuY2F0Y2goKCkgPT4ge30p
            OwogICAgICAgICAgICAgICAgICAgICAgICAgICAgbGV0IHggPSBuZXcgVWludDhBcnJheSgxMDI0
            ICogMTAyNCAqIDEwKTsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNyeXB0by5nZXRSYW5k
            b21WYWx1ZXMoeCk7CiAgICAgICAgICAgICAgICAgICAgICAgIH0sIDApOwogICAgICAgICAgICAg
            ICAgICAgIDxcL3NjcmlwdD4KICAgICAgICAgICAgICAgIDwvYm9keT4KICAgICAgICAgICAgICAg
            IDwvaHRtbD4KICAgICAgICAgICAgYDsKICAgIAogICAgICAgICAgICBmcmFtZS5zcmNkb2MgPSBy
            ZXNwcmluZ1NjcmlwdDsKICAgICAgICA8L3NjcmlwdD4KICAgIDwvYm9keT4KPC9odG1sPg==
"""

    private enum AssetError: LocalizedError {
        case materialization
        var errorDescription: String? { "failed to materialize respring payload" }
    }

    static func materialize() {
        let dest = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("respring.html")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let data = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) else {
            UILogger.log("[respring] payload decode failed")
            return
        }
        do {
            try data.write(to: dest, options: .atomic)
            UILogger.log("[respring] payload ready")
        } catch {
            UILogger.log("[respring] write failed: \(error.localizedDescription)")
        }
    }
}
