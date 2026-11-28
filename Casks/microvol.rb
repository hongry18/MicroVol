cask "microvol" do
  version "1.1.2"
  sha256 "ce20974b8837e5b0fedde8d4c33fea2921cda8713e59c0eb12bda2677a6bb9ab"

  url "https://github.com/hongry18/MicroVol/releases/download/v#{version}/MicroVol-arm64.zip"
  name "MicroVol"
  desc "Lightweight Apple Silicon external monitor DDC and system volume controller"
  homepage "https://github.com/hongry18/MicroVol"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "MicroVol.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/MicroVol.app"],
                   sudo: false
  end

  caveats <<~EOS
    MicroVol requires Accessibility permission to intercept keyboard volume keys.
    Grant access in System Settings > Privacy & Security > Accessibility.
    After upgrading, you may need to remove and re-add MicroVol in Accessibility.
  EOS
end
