package com.swiftgreen.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch

data class SearchResults(
    val notifications: List<NotificationHistoryManager.NotificationRecord> = emptyList(),
    val clipboardEntries: List<ClipboardRecord> = emptyList(),
    val fileTransfers: List<FileTransferManager.TransferRecord> = emptyList(),
    val isSearching: Boolean = false
)

class SearchViewModel {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    val searchQuery = MutableStateFlow("")

    private val _searchResults = MutableStateFlow(SearchResults())
    val searchResults: StateFlow<SearchResults> = _searchResults.asStateFlow()

    init {
        scope.launch {
            @OptIn(kotlinx.coroutines.FlowPreview::class, kotlinx.coroutines.ExperimentalCoroutinesApi::class)
            searchQuery
                .debounce(150)
                .flatMapLatest { query ->
                    flow {
                        if (query.isBlank()) {
                            emit(SearchResults())
                            return@flow
                        }
                        emit(_searchResults.value.copy(isSearching = true))

                        val q = query.trim()

                        val notifications = NotificationHistoryManager.history.value
                            .filter { it.matchesQuery(q) }

                        val clipboardEntries = ClipboardHistoryManager.history.value
                            .filter { it.matchesQuery(q) }

                        val fileTransfers = FileTransferManager.transferHistory.value
                            .filter { it.matchesQuery(q) }

                        emit(
                            SearchResults(
                                notifications = notifications,
                                clipboardEntries = clipboardEntries,
                                fileTransfers = fileTransfers,
                                isSearching = false
                            )
                        )
                    }.flowOn(Dispatchers.IO)
                }
                .collect { _searchResults.value = it }
        }
    }

    fun destroy() {
        scope.cancel()
    }

    private fun NotificationHistoryManager.NotificationRecord.matchesQuery(query: String): Boolean {
        val q = query.lowercase()
        return appName.lowercase().contains(q) ||
                title.lowercase().contains(q) ||
                body.lowercase().contains(q)
    }

    private fun ClipboardRecord.matchesQuery(query: String): Boolean {
        if (text.isBlank()) return false
        return text.lowercase().contains(query.lowercase())
    }

    private fun FileTransferManager.TransferRecord.matchesQuery(query: String): Boolean {
        return filename.lowercase().contains(query.lowercase())
    }
}
