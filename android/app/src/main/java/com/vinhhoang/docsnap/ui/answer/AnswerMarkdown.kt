package com.vinhhoang.docsnap.ui.answer

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle

/** One block of an answer. `indent` is the nesting level of a list item (0 = top level). */
sealed interface MdBlock {
    data class Heading(val level: Int, val text: String) : MdBlock
    data class Bullet(val text: String, val indent: Int = 0) : MdBlock
    data class Numbered(val number: String, val text: String, val indent: Int = 0) : MdBlock
    /** Lines of one paragraph, joined with '\n' (math steps stay on their own lines). */
    data class Paragraph(val text: String) : MdBlock
}

/**
 * The small Markdown subset the server asks Claude to use: `###` headings, `**bold**`, `*italic*`,
 * `-` / `1.` lists and paragraphs. Hand-written so no Markdown library is needed; anything else is
 * shown as plain text, and an unmatched marker is kept literally.
 */
object AnswerMarkdown {
    val Bold = SpanStyle(fontWeight = FontWeight.Bold)
    val Italic = SpanStyle(fontStyle = FontStyle.Italic)

    private val headingRegex = Regex("^(#{1,6})(?:\\s+(.*?))?(?:\\s+#+)?\\s*$")
    private val numberedRegex = Regex("^(\\d{1,3})[.)]\\s+(.*)$")
    private val ruleRegex = Regex("^([-*_])(\\s*\\1){2,}$")

    fun parse(source: String): List<MdBlock> {
        val blocks = mutableListOf<MdBlock>()
        val paragraph = mutableListOf<String>()
        fun flush() {
            if (paragraph.isNotEmpty()) {
                blocks += MdBlock.Paragraph(paragraph.joinToString("\n"))
                paragraph.clear()
            }
        }
        for (raw in source.replace("\r\n", "\n").replace('\r', '\n').split('\n')) {
            val line = raw.trim()
            val indent = (leadingSpaces(raw) / 2).coerceAtMost(3)
            when {
                line.isEmpty() -> flush()
                ruleRegex.matches(line) -> flush()
                line.startsWith("#") && headingRegex.matches(line) -> {
                    flush()
                    val match = headingRegex.matchEntire(line)!!
                    val text = match.groupValues[2].trim()
                    if (text.isNotEmpty()) blocks += MdBlock.Heading(match.groupValues[1].length, text)
                }
                line.startsWith("- ") || line.startsWith("* ") || line.startsWith("• ") -> {
                    flush()
                    blocks += MdBlock.Bullet(line.substring(2).trim(), indent)
                }
                numberedRegex.matches(line) -> {
                    flush()
                    val match = numberedRegex.matchEntire(line)!!
                    blocks += MdBlock.Numbered(match.groupValues[1], match.groupValues[2].trim(), indent)
                }
                else -> paragraph += line
            }
        }
        flush()
        return blocks
    }

    /** Inline `**bold**` and `*italic*` (nestable); `\*` is a literal star. */
    fun inline(text: String, bold: SpanStyle = Bold, italic: SpanStyle = Italic): AnnotatedString =
        buildAnnotatedString { appendInline(this, text, bold, italic) }

    /** Plain text without Markdown markers, for Copy and Share (pasting `**` into Zalo looks broken). */
    fun plainText(source: String): String {
        val out = StringBuilder()
        var previous: MdBlock? = null
        for (block in parse(source)) {
            if (previous != null) {
                val bothList = previous.isListItem() && block.isListItem()
                out.append(if (bothList) "\n" else "\n\n")
            }
            when (block) {
                is MdBlock.Heading -> out.append(inline(block.text).text)
                is MdBlock.Bullet -> out.append("  ".repeat(block.indent)).append("• ").append(inline(block.text).text)
                is MdBlock.Numbered -> out.append("  ".repeat(block.indent)).append(block.number).append(". ").append(inline(block.text).text)
                is MdBlock.Paragraph -> out.append(inline(block.text).text)
            }
            previous = block
        }
        return out.toString()
    }

    private fun MdBlock.isListItem() = this is MdBlock.Bullet || this is MdBlock.Numbered

    private fun leadingSpaces(line: String): Int {
        var n = 0
        for (c in line) {
            when (c) {
                ' ' -> n += 1
                '\t' -> n += 4
                else -> return n
            }
        }
        return n
    }

    private fun appendInline(builder: AnnotatedString.Builder, s: String, bold: SpanStyle, italic: SpanStyle) {
        val plain = StringBuilder()
        fun flush() {
            if (plain.isNotEmpty()) {
                builder.append(plain.toString())
                plain.clear()
            }
        }
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length && s[i + 1] in "*_\\#") {
                plain.append(s[i + 1])
                i += 2
                continue
            }
            if (s.startsWith("**", i)) {
                var close = s.indexOf("**", i + 2)
                // "***x***": let the bold span keep the inner "*x*" so it becomes italic too.
                while (close >= 0 && close + 2 < s.length && s[close + 2] == '*') close++
                // Like CommonMark: "** b **" is not bold (the content can't start or end with a space).
                val inner = if (close > i + 2) s.substring(i + 2, close) else ""
                if (inner.isNotEmpty() && !inner.first().isWhitespace() && !inner.last().isWhitespace()) {
                    flush()
                    builder.withStyle(bold) { appendInline(this, inner, bold, italic) }
                    i = close + 2
                } else {
                    plain.append("**")
                    i += 2
                }
                continue
            }
            if (c == '*' && i + 1 < s.length && !s[i + 1].isWhitespace()) {
                val close = italicClose(s, i + 1)
                if (close > i + 1) {
                    flush()
                    builder.withStyle(italic) { appendInline(this, s.substring(i + 1, close), bold, italic) }
                    i = close + 1
                    continue
                }
            }
            plain.append(c)
            i++
        }
        flush()
    }

    /** Index of the single `*` closing an italic run that starts at `from`, or -1. Skips over `**…**`. */
    private fun italicClose(s: String, from: Int): Int {
        var j = from
        while (j < s.length) {
            when {
                s[j] == '\\' -> j += 2
                s.startsWith("**", j) -> {
                    val end = s.indexOf("**", j + 2)
                    if (end < 0) return -1
                    j = end + 2
                }
                s[j] == '*' && !s[j - 1].isWhitespace() -> return j
                else -> j++
            }
        }
        return -1
    }
}
