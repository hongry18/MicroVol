cask "microvol" do
  version "1.1.0"
  sha256 "4a7890f47354adc8f326860c405baf208e8b641e0af6ad0e15bc7feefffd28f5"

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
