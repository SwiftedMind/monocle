import ArgumentParser

@main
enum MonocleMain {
  static func main() async {
    await MonocleCommand.main()
  }
}
