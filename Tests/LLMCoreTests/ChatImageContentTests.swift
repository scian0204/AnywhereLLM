import Testing
import Foundation
@testable import LLMCore

@Suite struct ChatImageContentTests {
    // MARK: - OpenAI

    @Test func openAINoImageIsPlainString() {
        #expect(ChatImageContent.openAI(text: "hi", imageBase64: nil) as? String == "hi")
        #expect(ChatImageContent.openAI(text: "hi", imageBase64: "") as? String == "hi")
    }

    @Test func openAIWithImageBuildsTextThenImagePart() {
        guard let arr = ChatImageContent.openAI(text: "what is this", imageBase64: "AAAB") as? [[String: Any]] else {
            Issue.record("expected content-parts array"); return
        }
        #expect(arr.count == 2)
        #expect(arr[0]["type"] as? String == "text")
        #expect(arr[0]["text"] as? String == "what is this")
        #expect(arr[1]["type"] as? String == "image_url")
        #expect((arr[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AAAB")
    }

    @Test func openAIEmptyTextOmitsTextPart() {
        guard let arr = ChatImageContent.openAI(text: "", imageBase64: "AAAB") as? [[String: Any]] else {
            Issue.record("expected content-parts array"); return
        }
        #expect(arr.count == 1)
        #expect(arr[0]["type"] as? String == "image_url")
    }

    // MARK: - Anthropic

    @Test func anthropicNoImageIsPlainString() {
        #expect(ChatImageContent.anthropic(text: "hi", imageBase64: nil) as? String == "hi")
    }

    @Test func anthropicWithImageBuildsBase64SourceBlock() {
        guard let arr = ChatImageContent.anthropic(text: "hi", imageBase64: "ZZ9") as? [[String: Any]] else {
            Issue.record("expected content-blocks array"); return
        }
        #expect(arr.count == 2)
        #expect(arr[0]["type"] as? String == "text")
        #expect(arr[1]["type"] as? String == "image")
        let source = arr[1]["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == "ZZ9")
    }

    // MARK: - Ollama

    @Test func ollamaImagesAreRawBase64NoDataPrefix() {
        #expect(ChatImageContent.ollamaImages("AAAB") == ["AAAB"])
    }

    @Test func ollamaImagesNilWhenNoImage() {
        #expect(ChatImageContent.ollamaImages(nil) == nil)
        #expect(ChatImageContent.ollamaImages("") == nil)
    }
}
