cask "andytici" do
  version "0.1.0"
  # PLACEHOLDER: 在首个 DMG 上传 GitHub Release 后替换为 `shasum -a 256 Andy题词-#{version}.dmg`
  sha256 :no_check

  url "https://github.com/AIPMAndy/andytici/releases/download/v#{version}/Andy题词-#{version}.dmg"
  name "Andy题词"
  desc "口播创作者提词器（macOS 原生）— 抖音 / 小红书 / 视频号 专用"
  homepage "https://github.com/AIPMAndy/andytici"

  livecheck do
    url :url
    strategy :github_latest_release
  end

  app "Andy题词.app"

  zap trash: [
    "~/Library/Application Support/dev.andy.tici",
    "~/Library/Preferences/dev.andy.tici.plist",
    "~/Library/Caches/dev.andy.tici",
  ]
end
