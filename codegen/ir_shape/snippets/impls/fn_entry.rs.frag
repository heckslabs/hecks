fn entry(keyword: &str, parser: BlockParser) -> BlockGrammarEntry {
    BlockGrammarEntry { keyword: keyword.into(), parser }
}
