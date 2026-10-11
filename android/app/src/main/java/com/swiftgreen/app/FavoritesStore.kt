package com.swiftgreen.app

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import androidx.core.content.edit

object FavoritesStore {
    private const val PREFS_NAME = "swiftgreen_favorites"
    private const val KEY_FAVORITE_IDS = "favorite_contact_ids"

    private var prefs: SharedPreferences? = null
    private val _favoriteIds = MutableStateFlow<Set<Long>>(emptySet())
    val favoriteIds: StateFlow<Set<Long>> = _favoriteIds.asStateFlow()

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        loadFromPrefs()
    }

    private fun loadFromPrefs() {
        val jsonString = prefs?.getString(KEY_FAVORITE_IDS, "[]") ?: "[]"
        _favoriteIds.value = try {
            val array = JSONArray(jsonString)
            (0 until array.length()).map { array.getLong(it) }.toSet()
        } catch (e: Exception) {
            emptySet()
        }
    }

    fun isFavorite(contactId: Long): Boolean = _favoriteIds.value.contains(contactId)

    fun setFavorite(contactId: Long, favorite: Boolean) {
        val current = _favoriteIds.value
        _favoriteIds.value = if (favorite) current + contactId else current - contactId
        persist()
    }

    private fun persist() {
        val array = JSONArray()
        _favoriteIds.value.forEach { array.put(it) }
        prefs?.edit { putString(KEY_FAVORITE_IDS, array.toString()) }
    }
}
