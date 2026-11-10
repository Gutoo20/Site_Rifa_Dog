using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web;

// Registro de uma compra (um envio de comprovante)
public class Compra
{
    public string Id;          // GUID sem hifens (32 hex)
    public DateTime Data;
    public string Nome;
    public string Contato;
    public List<int> Numeros = new List<int>();
    public string Arquivo;     // nome do comprovante em App_Data/comprovantes
}

// Acesso compartilhado aos dados da rifa (site publico e admin usam a MESMA trava)
public static class RifaDados
{
    public static readonly object Trava = new object();

    const string FormatoData = "yyyy-MM-dd HH:mm:ss";

    public static string Pasta(HttpContext ctx)
    {
        string p = ctx.Server.MapPath("~/App_Data");
        Directory.CreateDirectory(p);
        return p;
    }

    public static string PastaComprovantes(HttpContext ctx)
    {
        string p = Path.Combine(Pasta(ctx), "comprovantes");
        Directory.CreateDirectory(p);
        return p;
    }

    // ---------- numeros vendidos ----------
    public static List<int> LerVendidos(HttpContext ctx)
    {
        var lista = new List<int>();
        string caminho = Path.Combine(Pasta(ctx), "vendidos.txt");
        if (!File.Exists(caminho)) return lista;
        foreach (string linha in File.ReadAllLines(caminho, Encoding.UTF8))
        {
            int n;
            if (int.TryParse(linha.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out n) && !lista.Contains(n))
                lista.Add(n);
        }
        lista.Sort();
        return lista;
    }

    public static void GravarVendidos(HttpContext ctx, IEnumerable<int> numeros)
    {
        var linhas = numeros.Distinct().OrderBy(n => n)
            .Select(n => n.ToString(CultureInfo.InvariantCulture)).ToArray();
        GravarAtomico(Path.Combine(Pasta(ctx), "vendidos.txt"), linhas);
    }

    public static void AdicionarVendidos(HttpContext ctx, IEnumerable<int> numeros)
    {
        var todos = LerVendidos(ctx);
        todos.AddRange(numeros);
        GravarVendidos(ctx, todos);
    }

    // ---------- compras ----------
    public static List<Compra> LerCompras(HttpContext ctx)
    {
        var lista = new List<Compra>();
        string caminho = Path.Combine(Pasta(ctx), "compras.txt");
        if (!File.Exists(caminho)) return lista;
        foreach (string linha in File.ReadAllLines(caminho, Encoding.UTF8))
        {
            string[] p = linha.Split('|');
            DateTime data;
            if (p.Length != 6 || !IdValido(p[0])) continue;
            if (!DateTime.TryParseExact(p[1], FormatoData, CultureInfo.InvariantCulture, DateTimeStyles.None, out data)) continue;

            var c = new Compra { Id = p[0], Data = data, Nome = p[2], Contato = p[3], Arquivo = p[5] };
            foreach (string s in p[4].Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                int n;
                if (int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n)) c.Numeros.Add(n);
            }
            lista.Add(c);
        }
        return lista;
    }

    public static void GravarCompras(HttpContext ctx, IEnumerable<Compra> compras)
    {
        GravarAtomico(Path.Combine(Pasta(ctx), "compras.txt"), compras.Select(Linha).ToArray());
    }

    public static void AdicionarCompra(HttpContext ctx, Compra c)
    {
        File.AppendAllText(Path.Combine(Pasta(ctx), "compras.txt"), Linha(c) + Environment.NewLine, Encoding.UTF8);
    }

    public static void RegistrarLiberacao(HttpContext ctx, string texto)
    {
        File.AppendAllText(Path.Combine(Pasta(ctx), "liberacoes.log"),
            DateTime.Now.ToString(FormatoData, CultureInfo.InvariantCulture) + " | " + Limpa(texto) + Environment.NewLine,
            Encoding.UTF8);
    }

    static string Linha(Compra c)
    {
        return c.Id + "|" + c.Data.ToString(FormatoData, CultureInfo.InvariantCulture) + "|" + Limpa(c.Nome) + "|" + Limpa(c.Contato) + "|"
            + string.Join(",", c.Numeros.Select(n => n.ToString(CultureInfo.InvariantCulture)).ToArray()) + "|" + Limpa(c.Arquivo);
    }

    // Grava em arquivo temporario e troca, para nao corromper em caso de falha no meio
    static void GravarAtomico(string caminho, string[] linhas)
    {
        string tmp = caminho + ".tmp";
        File.WriteAllLines(tmp, linhas, Encoding.UTF8);
        if (File.Exists(caminho)) File.Replace(tmp, caminho, null);
        else File.Move(tmp, caminho);
    }

    // ---------- utilitarios ----------
    public static bool IdValido(string id)
    {
        if (id == null || id.Length != 32) return false;
        foreach (char c in id)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }

    // Remove quebras de linha e o separador (evita injecao de campos/linhas)
    public static string Limpa(string s)
    {
        return (s ?? "").Replace("\r", " ").Replace("\n", " ").Replace("|", "/");
    }

    public static string Num(int n) { return n.ToString(CultureInfo.InvariantCulture); }

    public static string ListaNum(IEnumerable<int> nums)
    {
        return string.Join(",", nums.Select(n => Num(n)).ToArray());
    }

    public static string Js(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in s ?? "")
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '<': sb.Append("\\u003c"); break;
                case '>': sb.Append("\\u003e"); break;
                default:
                    if (c < 32) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }
}
