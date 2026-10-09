package today.cypherpunk.emanator

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Every strings file exists in every language with the same names, the same
 * format placeholders, and the plural forms the language needs — the app's
 * twin of the web's test/i18n/locale_files_test.rb. A missing translation
 * would otherwise fall back to English without complaint.
 */
class StringsParityTest {
    private val res = listOf(File("src/main/res"), File("app/src/main/res")).first { it.exists() }
    private val locales = listOf("sk", "cs", "es")
    private val placeholder = Regex("""%(\d+\$)?[sdf]""")

    // Android plural categories each language actually uses for integers.
    private val requiredPlurals = mapOf(
        "en" to setOf("one", "other"),
        "sk" to setOf("one", "few", "other"),
        "cs" to setOf("one", "few", "other"),
        "es" to setOf("one", "other"),
    )

    private data class Entry(val text: String?, val plurals: Map<String, String>?)

    private fun read(file: File): Map<String, Entry> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val out = linkedMapOf<String, Entry>()
        val strings = doc.getElementsByTagName("string")
        for (i in 0 until strings.length) {
            val e = strings.item(i) as Element
            if (e.getAttribute("translatable") == "false") continue
            out[e.getAttribute("name")] = Entry(e.textContent, null)
        }
        val plurals = doc.getElementsByTagName("plurals")
        for (i in 0 until plurals.length) {
            val e = plurals.item(i) as Element
            val items = e.getElementsByTagName("item")
            out[e.getAttribute("name")] = Entry(null, (0 until items.length).associate {
                val item = items.item(it) as Element
                item.getAttribute("quantity") to item.textContent
            })
        }
        return out
    }

    private fun placeholders(entry: Entry): Set<String> =
        ((entry.plurals?.values ?: listOf(entry.text.orEmpty())).flatMap { placeholder.findAll(it).map { m -> m.value } }).toSet()

    @Test
    fun everyFileExistsInEveryLanguageWithTheSameNames() {
        val englishFiles = File(res, "values").listFiles { f -> f.name.startsWith("strings") }!!
        assertTrue("no strings files found", englishFiles.isNotEmpty())

        for (englishFile in englishFiles) {
            val english = read(englishFile)
            for (locale in locales) {
                val file = File(res, "values-$locale/${englishFile.name}")
                assertTrue("values-$locale/${englishFile.name} is missing", file.exists())
                val translated = read(file)

                val missing = english.keys - translated.keys
                val extra = translated.keys - english.keys
                assertTrue("values-$locale/${englishFile.name} lacks: ${missing.take(10)}", missing.isEmpty())
                assertTrue("values-$locale/${englishFile.name} has extra: ${extra.take(10)}", extra.isEmpty())

                english.forEach { (name, entry) ->
                    val other = translated[name] ?: return@forEach
                    assertEquals("$locale $name changes placeholders", placeholders(entry), placeholders(other))
                    if (entry.plurals != null) {
                        val forms = other.plurals?.keys ?: emptySet()
                        val needed = requiredPlurals.getValue(locale)
                        assertTrue("$locale plural $name lacks ${needed - forms}", forms.containsAll(needed))
                    }
                }
            }
        }
    }
}
