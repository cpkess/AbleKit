import Foundation
import Testing

@testable import AbleKitCore

@Suite("Private Cloud Compute", .serialized)
struct CloudReasoningTests {

    @Test("Prompts bound for the cloud leave out the clipboard")
    func cloudPromptsOmitClipboard() {
        let desktop = DesktopContext(
            clipboard: ClipboardSnapshot(text: "correct horse battery staple"),
            arrangement: .fixture()
        )
        let context = AgentContext(goal: "g", desktop: desktop)
        #expect(PromptBuilder().planningPrompt(goal: "g", context: context).contains("correct horse"))
        #expect(!PromptBuilder(includesClipboard: false).planningPrompt(goal: "g", context: context).contains("correct horse"))
    }

    @Test("The refusal an app without access receives is recognised, however deeply it is wrapped")
    func recognisesAccessDenied() {
        let inner = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1046)
        let middle = NSError(domain: "FoundationModels.LanguageModelError", code: -1,
                             userInfo: ["NSMultipleUnderlyingErrorsKey": [inner]])
        let outer = NSError(domain: "FoundationModels.LanguageModelError", code: -1,
                            userInfo: ["NSMultipleUnderlyingErrorsKey": [middle]])
        #expect(CloudAccessMemory.isAccessDenied(outer))
    }

    @Test("Ordinary failures are not mistaken for a refusal")
    func ignoresOtherErrors() {
        #expect(!CloudAccessMemory.isAccessDenied(NSError(domain: NSURLErrorDomain, code: -1009)))
        #expect(!CloudAccessMemory.isAccessDenied(NSError(domain: "ModelManagerServices.ModelManagerError", code: 1001)))
    }

    @Test("A refusal is remembered until it is reset")
    func memory() {
        CloudAccessMemory.reset()
        #expect(!CloudAccessMemory.isDenied)
        CloudAccessMemory.recordDenied()
        #expect(CloudAccessMemory.isDenied)
        #expect(AppleIntelligenceProvider.cloudStatus() == .accessNotGranted || AppleIntelligenceProvider.cloudStatus() == .unsupportedSystem)
        #expect(AppleIntelligenceProvider(location: .privateCloudCompute).effectiveLocation() == .onDevice)
        CloudAccessMemory.reset()
        #expect(!CloudAccessMemory.isDenied)
    }

    @Test("On-device reasoning never uses the cloud, whatever its status")
    func onDeviceStaysLocal() {
        #expect(AppleIntelligenceProvider(location: .onDevice).effectiveLocation() == .onDevice)
    }
}
