package com.vinhhoang.docsnap.ui.answer

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AnswerMarkdownTest {
    private fun AnnotatedString.ranges(style: SpanStyle): List<String> =
        spanStyles.filter { it.item == style }.map { text.substring(it.start, it.end) }

    private val AnnotatedString.bold get() = ranges(AnswerMarkdown.Bold)
    private val AnnotatedString.italic get() = ranges(AnswerMarkdown.Italic)

    // MARK: - Blocks

    @Test fun headings() {
        val blocks = AnswerMarkdown.parse("### 1. Are v₁, v₂ independent?\n## Part B ##\n# Top\n####### seven")
        assertEquals(
            listOf(
                MdBlock.Heading(3, "1. Are v₁, v₂ independent?"),
                MdBlock.Heading(2, "Part B"),
                MdBlock.Heading(1, "Top"),
                MdBlock.Paragraph("####### seven"),
            ),
            blocks,
        )
    }

    @Test fun hashWithoutSpaceIsNotAHeading() {
        assertEquals(listOf(MdBlock.Paragraph("#hashtag and C#")), AnswerMarkdown.parse("#hashtag and C#"))
        assertEquals(listOf(MdBlock.Heading(3, "Using C#")), AnswerMarkdown.parse("### Using C#"))
        assertEquals(emptyList<MdBlock>(), AnswerMarkdown.parse("###"))
    }

    @Test fun listsAndParagraphs() {
        val source = """
            **Answer:** yes.

            - first
            * second
            • third
              - nested
            1. one
            2) two

            Step 1: x + 2 = 5
            Step 2: x = 3
        """.trimIndent()
        assertEquals(
            listOf(
                MdBlock.Paragraph("**Answer:** yes."),
                MdBlock.Bullet("first"),
                MdBlock.Bullet("second"),
                MdBlock.Bullet("third"),
                MdBlock.Bullet("nested", indent = 1),
                MdBlock.Numbered("1", "one"),
                MdBlock.Numbered("2", "two"),
                // Math steps stay on their own lines.
                MdBlock.Paragraph("Step 1: x + 2 = 5\nStep 2: x = 3"),
            ),
            AnswerMarkdown.parse(source),
        )
    }

    @Test fun windowsLineEndingsAndRules() {
        assertEquals(
            listOf(MdBlock.Paragraph("a\nb"), MdBlock.Paragraph("c")),
            AnswerMarkdown.parse("a\r\nb\r\n---\r\nc"),
        )
    }

    @Test fun emptyInput() {
        assertEquals(emptyList<MdBlock>(), AnswerMarkdown.parse(""))
        assertEquals(emptyList<MdBlock>(), AnswerMarkdown.parse("\n \n\t\n"))
        assertEquals("", AnswerMarkdown.inline("").text)
        assertEquals("", AnswerMarkdown.plainText(""))
    }

    // MARK: - Inline

    @Test fun boldAndItalic() {
        val s = AnswerMarkdown.inline("The **final answer** is *x = 3*.")
        assertEquals("The final answer is x = 3.", s.text)
        assertEquals(listOf("final answer"), s.bold)
        assertEquals(listOf("x = 3"), s.italic)
    }

    @Test fun nestedBoldInsideAListItem() {
        val block = AnswerMarkdown.parse("- **Answer:** the vectors are *not* independent").single() as MdBlock.Bullet
        val s = AnswerMarkdown.inline(block.text)
        assertEquals("Answer: the vectors are not independent", s.text)
        assertEquals(listOf("Answer:"), s.bold)
        assertEquals(listOf("not"), s.italic)
    }

    @Test fun italicInsideBoldAndBoldInsideItalic() {
        val a = AnswerMarkdown.inline("**bold *both* bold**")
        assertEquals("bold both bold", a.text)
        assertEquals(listOf("bold both bold"), a.bold)
        assertEquals(listOf("both"), a.italic)

        val b = AnswerMarkdown.inline("*it **both** it*")
        assertEquals("it both it", b.text)
        assertEquals(listOf("it both it"), b.italic)
        assertEquals(listOf("both"), b.bold)

        val c = AnswerMarkdown.inline("***all***")
        assertEquals("all", c.text)
        assertEquals(listOf("all"), c.bold)
        assertEquals(listOf("all"), c.italic)
    }

    @Test fun unmatchedDoubleStarStaysLiteral() {
        val s = AnswerMarkdown.inline("a ** b and **c")
        assertEquals("a ** b and **c", s.text)
        assertTrue(s.spanStyles.isEmpty())
    }

    @Test fun lonelyAndSpacedStarsStayLiteral() {
        assertEquals("2 * 3 * 4 = 24", AnswerMarkdown.inline("2 * 3 * 4 = 24").text)
        assertEquals("*not closed", AnswerMarkdown.inline("*not closed").text)
        assertEquals("****", AnswerMarkdown.inline("****").text)
        assertEquals("a*", AnswerMarkdown.inline("a*").text)
    }

    @Test fun escapedStar() {
        val s = AnswerMarkdown.inline("""a \*b\* c""")
        assertEquals("a *b* c", s.text)
        assertTrue(s.spanStyles.isEmpty())
    }

    @Test fun vietnameseText() {
        val blocks = AnswerMarkdown.parse("### Câu 1: Giải phương trình\n**Đáp án:** x = ±2\n- Bước 1: *chuyển vế* x² − 4 = 0")
        assertEquals(MdBlock.Heading(3, "Câu 1: Giải phương trình"), blocks[0])
        val answer = AnswerMarkdown.inline((blocks[1] as MdBlock.Paragraph).text)
        assertEquals("Đáp án: x = ±2", answer.text)
        assertEquals(listOf("Đáp án:"), answer.bold)
        val step = AnswerMarkdown.inline((blocks[2] as MdBlock.Bullet).text)
        assertEquals("Bước 1: chuyển vế x² − 4 = 0", step.text)
        assertEquals(listOf("chuyển vế"), step.italic)
    }

    @Test fun boldStyleIsBoldWeight() {
        assertEquals(FontWeight.Bold, AnswerMarkdown.Bold.fontWeight)
        assertEquals(FontStyle.Italic, AnswerMarkdown.Italic.fontStyle)
    }

    // MARK: - Plain text for Copy / Share

    @Test fun plainTextDropsMarkers() {
        val source = "### 1. Solve\n**x = 3**\n\n- step *one*\n- step two\n1. a\n\nDone."
        assertEquals("1. Solve\n\nx = 3\n\n• step one\n• step two\n1. a\n\nDone.", AnswerMarkdown.plainText(source))
    }
}
