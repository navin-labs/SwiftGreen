package com.swiftgreen.app

/**
 * A sender-supplied file name reduced to its last path component, so "../" can't
 * leave the destination folder (Downloads, or via ../../ this app's own data dir).
 * Empty when nothing usable is left; callers already reject an empty name.
 */
fun safeFileName(raw: String): String =
    raw.substringAfterLast('/').substringAfterLast('\\').takeUnless { it == "." || it == ".." }.orEmpty()
