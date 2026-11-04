# Test boundaries

All committed vector, hybrid, learning and benchmark providers are synthetic
lookup, constant or controlled test fixtures. They prove deterministic mechanics, not semantic relevance.
There is currently no real local embedding runtime or model artifact in this
repository. No real-model integration test has been run or represented as passing.

To add that gate, provision a version-pinned multilingual model locally without
an automatic download, implement LocalEmbeddingProvider, and create a separate
integration test target. Use held-out Arabic/English cross-language query/document
judgments and record model/tokenizer revisions, dimensions, device/backend and
Recall@10, MRR, NDCG@10. Do not reuse training labels as held-out evaluation.
The default deterministic test target must continue to work fully offline.

The held-out ranking test trains only on milk documents and labels; tea/juice
queries and documents are held out, with an unchanged water control. It verifies
transfer of rank-feature preferences. It does not test multilingual semantic
embeddings or justify a language-understanding claim.
