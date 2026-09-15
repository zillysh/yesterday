// Adapted from Apple MobileCLIPExplore / Hugging Face swift-coreml-transformers tokenizer.

import Foundation

struct BytePair: Hashable {
    let a: String
    let b: String

    init(_ a: String, _ b: String) {
        self.a = a
        self.b = b
    }

    init(tuple: [String]) {
        self.a = tuple[0]
        self.b = tuple[1]
    }
}

final class CLIPTokenizer {
    let bpeRanks: [BytePair: Int]
    private let encoder: [String: Int]
    private let decoder: [Int: String]
    let contextLength = 77

    init() {
        let mergesURL = Bundle.main.url(forResource: "clip-merges", withExtension: "txt")
            ?? Bundle.main.url(forResource: "clip-merges", withExtension: "txt", subdirectory: "Resources/MobileCLIP")
            ?? Bundle.main.url(forResource: "clip-merges", withExtension: "txt", subdirectory: "MobileCLIP")
        let vocabURL = Bundle.main.url(forResource: "clip-vocab", withExtension: "json")
            ?? Bundle.main.url(forResource: "clip-vocab", withExtension: "json", subdirectory: "Resources/MobileCLIP")
            ?? Bundle.main.url(forResource: "clip-vocab", withExtension: "json", subdirectory: "MobileCLIP")

        guard let mergesURL, let vocabURL,
              let bpeMergesTxt = try? String(contentsOf: mergesURL, encoding: .utf8),
              let json = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int].self, from: json)
        else {
            bpeRanks = [:]
            encoder = [:]
            decoder = [:]
            return
        }

        let arr = bpeMergesTxt.split(separator: "\n").map(String.init)
        var ranks: [BytePair: Int] = [:]
        for i in 1..<arr.count {
            let tuple = arr[i].split(separator: " ").map(String.init)
            guard tuple.count >= 2 else { continue }
            ranks[BytePair(tuple: tuple)] = i - 1
        }
        bpeRanks = ranks
        encoder = vocab
        decoder = Dictionary(uniqueKeysWithValues: vocab.map { ($0.value, $0.key) })
    }

    var isReady: Bool { !encoder.isEmpty && !bpeRanks.isEmpty }

    func byteEncode(text: String) -> [String] {
        let pattern =
            "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let matches = regex.matches(
            in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)
        )
        let tokens = matches.map { match -> String in
            let range = Range(match.range, in: text)!
            return String(text[range])
        }
        return tokens.map { token in
            Array(token.utf8).map { byteEncoder[$0]! }.joined()
        }
    }

    private func getPairs(word: [String]) -> Set<BytePair> {
        var s = Set<BytePair>()
        for i in 0..<(word.count - 1) {
            s.insert(BytePair(word[i], word[i + 1]))
        }
        return s
    }

    func bpe(token: String) -> String {
        if token.count <= 1 { return token + "</w>" }

        var word = Array(token).map(String.init)
        let last = (word.last ?? "") + "</w>"
        word.removeLast()
        word.append(last)
        var pairs = Array(getPairs(word: word))
        if pairs.isEmpty { return token + "</w>" }

        while true {
            let bigrams = pairs.filter { bpeRanks[$0] != nil }
            if bigrams.isEmpty { break }
            let bigram = bigrams.min { bpeRanks[$0]! < bpeRanks[$1]! }!
            let first = bigram.a
            let second = bigram.b
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if let j = word[i..<word.count].firstIndex(of: first) {
                    newWord.append(contentsOf: word[i..<j])
                    i = j
                } else {
                    newWord.append(contentsOf: word[i..<word.count])
                    break
                }
                if word[i] == first && i < word.count - 1 && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
            pairs = Array(getPairs(word: word))
        }
        return word.joined(separator: " ")
    }

    func tokenize(text: String) -> [String] {
        var tokens: [String] = []
        for token in byteEncode(text: text.lowercased()) {
            tokens.append(contentsOf: bpe(token: token).split(separator: " ").map(String.init))
        }
        return tokens
    }

    func encode(text: String) -> [Int] {
        tokenize(text: text).compactMap { encoder[$0] }
    }

    func encodeFull(text: String) -> [Int] {
        guard let bos = encoder["<|startoftext|>"], let eos = encoder["<|endoftext|>"] else {
            return Array(repeating: 0, count: contextLength)
        }
        let tokens = encode(text: text)
        var full = Array(repeating: 0, count: contextLength)
        full[0] = bos
        let maxTokens = min(tokens.count, contextLength - 2)
        for i in 0..<maxTokens {
            full[i + 1] = tokens[i]
        }
        full[maxTokens + 1] = eos
        return full
    }
}
