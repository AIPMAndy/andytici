cask "andytici" do
  version "0.1.0"
  sha256 "<待发布后填入>"

  url "https://github.com/andy/andytici/releases/download/v#{version}/Andy题词-#{version}.dmg"
  name "Andy题词"
  desc "口播创作者提词器（macOS 原生）— 抖音 / 小红书 / 视频号 专用"
  homepage "https://github.com/andy/andytici"

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
