# frozen_string_literal: true

require_relative("../../lib/repository_link")

RSpec.describe(RepositoryLink) {
  describe(".from") {
    it("parses https GitHub remotes", :aggregate_failures) {
      link = described_class.from("https://github.com/onevcat/Kingfisher.git")

      expect(link).not_to(be_nil)
      expect(link.compare_url("7.0.0", "8.0.0")).to(eq("https://github.com/onevcat/Kingfisher/compare/7.0.0...8.0.0"))
      expect(link.release_link).to(eq("[Releases](https://github.com/onevcat/Kingfisher/releases)"))
    }

    it("parses scp-style ssh remotes") {
      link = described_class.from("git@github.com:owner/repo.git")

      expect(link.compare_url("1.0.0", "2.0.0")).to(eq("https://github.com/owner/repo/compare/1.0.0...2.0.0"))
    }

    it("strips credentials from https remotes", :aggregate_failures) {
      link = described_class.from("https://user:token@github.com/owner/repo.git")

      expect(link.compare_url("1.0.0", "2.0.0")).to(eq("https://github.com/owner/repo/compare/1.0.0...2.0.0"))
    }

    it("parses GitLab subgroup remotes", :aggregate_failures) {
      link = described_class.from("https://gitlab.com/group/subgroup/project.git")

      expect(link.compare_url("1.0.0", "2.0.0"))
        .to(eq("https://gitlab.com/group/subgroup/project/-/compare/1.0.0...2.0.0"))
      expect(link.release_link).to(eq("[Releases](https://gitlab.com/group/subgroup/project/-/releases)"))
    }

    it("parses Bitbucket remotes with reversed compare order", :aggregate_failures) {
      link = described_class.from("https://bitbucket.org/workspace/repo.git")

      expect(link.compare_url("1.0.0", "2.0.0"))
        .to(eq("https://bitbucket.org/workspace/repo/branches/compare/2.0.0..1.0.0"))
      expect(link.release_link).to(eq("[Tags](https://bitbucket.org/workspace/repo/downloads/?tab=tags)"))
    }

    it("returns nil for unsupported hosts") {
      expect(described_class.from("https://example.com/owner/repo.git")).to(be_nil)
    }

    it("returns nil for unparseable values", :aggregate_failures) {
      expect(described_class.from("not a url")).to(be_nil)
      expect(described_class.from(nil)).to(be_nil)
      expect(described_class.from("https://github.com/just-owner")).to(be_nil)
    }
  }

  describe("#markdown_links") {
    let(:link) { described_class.from("https://github.com/owner/repo") }

    it("renders a single compare link plus the release link") {
      markdown = link.markdown_links([{ current: "1.0.0", available: "1.1.0" }])

      expect(markdown).to(eq(
                            "[Compare](https://github.com/owner/repo/compare/1.0.0...1.1.0)<br>" \
                            "[Releases](https://github.com/owner/repo/releases)"
                          ))
    }

    it("numbers compare links when there are multiple updates", :aggregate_failures) {
      markdown = link.markdown_links(
        [
          { current: "1.0.0", available: "1.1.0" },
          { current: "1.1.0", available: "2.0.0" },
        ]
      )

      expect(markdown).to(include("[Compare 1](https://github.com/owner/repo/compare/1.0.0...1.1.0)"))
      expect(markdown).to(include("[Compare 2](https://github.com/owner/repo/compare/1.1.0...2.0.0)"))
    }

    it("joins links with a custom separator") {
      markdown = link.markdown_links([{ current: "1.0.0", available: "1.1.0" }], separator: " · ")

      expect(markdown).to(eq(
                            "[Compare](https://github.com/owner/repo/compare/1.0.0...1.1.0) · " \
                            "[Releases](https://github.com/owner/repo/releases)"
                          ))
    }

    it("URL-encodes refs in compare links") {
      markdown = link.markdown_links([{ current: "v1 beta", available: "2.0.0" }])

      expect(markdown).to(include("compare/v1+beta...2.0.0"))
    }
  }
}
