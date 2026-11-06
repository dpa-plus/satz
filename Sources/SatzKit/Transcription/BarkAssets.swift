import Foundation

/// The publisher's CoreML export, pinned and verified before compilation.
public enum BarkAssets {
    public static let revision = "d87f288a9a0b0cdb92228057e168ce575b300a6b"
    public static let baseURL = URL(string: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro/resolve/\(revision)/coreml/")!
    public static let files: [SherpaModel.File] = [
        .init("Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 11612, sha256: "00cd3bdf438e859eff16d1376cab86f6214d0e44b1876316e30550e35d012763"),
        .init("Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 23604992, sha256: "b6bfa9053e8e20d1e80a7522ddba5c66e2c8c77cfc956d4ebccf749baf4d3d69"),
        .init("Decoder.mlpackage/Manifest.json", 617, sha256: "123808ff526bf8d5f47b69d5833ff91477f438f92056a3531ae0a7b4f2945d7e"),
        .init("Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 1206573, sha256: "d82718558f523dc13f9c0ede57d6f8e37d953950808a5aaa3a4633a7f752dd77"),
        .init("Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 1195742464, sha256: "619757bd47bc5cc131a85e54e94ffacc1b8c1bce737c1f1f6569eda8621a30d6"),
        .init("Encoder.mlpackage/Manifest.json", 617, sha256: "a6f16e318952af66b69fa84820b6417846ad0c9208a3c2779aa788a7c244a75e"),
        .init("JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", 8759, sha256: "1057c2d9e9efce23258dbf2e7747e6facf7a42f4fcbcf2a21cdd160e065b18ac"),
        .init("JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 12642764, sha256: "90257de4d4582921c31db6efe9668017274b7c4cfdfe5aac9b9183233f7a9bdd"),
        .init("JointDecisionv3.mlpackage/Manifest.json", 617, sha256: "264b4403e1cada9a6148a10190e91b9e7fe6ead871db0aedcd87d2f4d84df1e7"),
        .init("LICENSE", 19347, sha256: "41003d4a74749c0220e33dd415042164b5a1093ed401f36277234f772d22d3d0"),
        .init("LICENSE-CC-BY-4.0", 18657, sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        .init("NOTICE", 755, sha256: "4e48ccdb8c5fd85129a709c7548bc149e878a6d1340114c0ada719dafdc37c00"),
        .init("Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", 18839, sha256: "dd4a5266ed9048aae620e73aa983eab93256654a343ded1226f9456b79f79a67"),
        .init("Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 1184512, sha256: "7a31e2bd311bfa97ea3fe73d4a6c029824327a71590397bd8784089a88754a77"),
        .init("Preprocessor.mlpackage/Manifest.json", 617, sha256: "75753d7f53c12f47bef18a0f84eacdf8e7e93db1a2e3af368c50b4f686317220"),
        .init("parakeet_v3_vocab.json", 143080, sha256: "3c278905d679b4b3e6b7be337edb8f9c0fce73a3708d5fe7a4a3bc7a12e719e1"),
    ]
    public static var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}
