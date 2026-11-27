cask "microvol" do
  version "1.0.0"
  sha256 "5b0eec53eb15bcdda575ab575dcd38da3e8b8ead22ce92a9e810d56cf5912af2"

  url "https://github.com/hongry18/MicroVol/releases/download/v#{version}/MicroVol-arm64.zip"
  name "MicroVol"
  desc "Lightweight Apple Silicon external monitor DDC and system volume controller"
  homepage "https://github.com/hongry18/MicroVol"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "MicroVol.app"

  caveats <<~EOS
    MicroVol is ad-hoc signed. If macOS blocks it on first launch, run:
      xattr -cr /Applications/MicroVol.app

    MicroVol requires Accessibility permission to intercept keyboard volume keys.
    Grant access in System Settings > Privacy & Security > Accessibility.
    After upgrading, you may need to remove and re-add MicroVol in Accessibility.
  EOS
end
