'use strict';

// Synthetic, local-only data. Production embedding models and dimensions are
// configured independently; this check needs no credentials or network access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { TriviumDB } = require('triviumdb');

assert.equal(typeof TriviumDB, 'function', 'TriviumDB native export is missing');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vcp-triviumdb-smoke-'));
const databasePath = path.join(directory, 'smoke.tdb');
const options = {
    dim: 3,
    dtype: 'f32',
    storageMode: 'mmap',
    syncMode: 'normal',
    loadTextIndex: true,
};
const query = [1, 0, 0];
const text = 'vcp cold knowledge persistence probe';
let database;

try {
    database = new TriviumDB(databasePath, options);
    const expectedId = database.insert(query, { text, source: 'ci-smoke' });
    database.insert([0, 1, 0], { text: 'unrelated document', source: 'ci-smoke' });
    database.indexText(expectedId, text);
    database.buildTextIndex();

    function verifySearch(label) {
        const hits = database.search(query, 1, 0, 0.5);
        assert.equal(hits.length, 1, `${label}: vector search returned no result`);
        assert.equal(hits[0].id, expectedId, `${label}: wrong nearest document`);
        assert.equal(hits[0].payload.text, text, `${label}: stored text was not preserved`);
        const hybrid = database.searchHybrid(query, text, 1, 0, 0.1, 0.5);
        assert.ok(hybrid.some(hit => hit.id === expectedId), `${label}: hybrid search failed`);
    }

    verifySearch('created');
    database.flush();
    database.close();
    database = null;

    database = new TriviumDB(databasePath, options);
    verifySearch('reopened');
    console.log('TriviumDB native smoke passed: create, insert, hybrid search, flush, reopen, search');
} finally {
    try {
        if (database) database.close();
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}
