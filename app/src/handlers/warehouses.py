from dataclasses import dataclass

from prompt_toolkit import prompt
from prompt_toolkit.completion import WordCompleter
from psycopg import Connection
from psycopg.rows import class_row
from rich.panel import Panel
from rich.table import Table

from console import console, render_error
from db import get_conn
from validators import ChoiceValidator, NonEmptyValidator, YesNoValidator
from auth import ALL_ROLES, ROLE_CATALOG_MANAGER
from commands import command, CATEGORY_WAREHOUSES


@dataclass
class Warehouse:
    id: int
    city: str
    address: str
    label: str | None
    is_central: bool


def _render_warehouse(warehouse: Warehouse) -> None:
    table = Table(show_header=False, box=None, padding=(0, 2))

    table.add_column("Поле", style="bold cyan", width=15)
    table.add_column("Значение", style="white")

    table.add_row("ID", str(warehouse.id))
    table.add_row("Город", warehouse.city)
    table.add_row("Адрес", warehouse.address)
    table.add_row("Метка", warehouse.label or "")
    table.add_row("Центральный", "да" if warehouse.is_central else "нет")

    panel = Panel(
        table,
        expand=False,
        title=f"[bold green]Склад #{warehouse.id}[/bold green]",
        border_style="green",
    )

    console.print(panel)


_SELECT_WAREHOUSE = """
    SELECT w.id, c.name AS city, w.address, w.label, w.is_central
    FROM catalog.warehouses w
    JOIN catalog.cities c ON c.id = w.city_id
"""


def _find_warehouse(_id: str) -> Warehouse | None:
    conn = get_conn()
    with conn.cursor(row_factory=class_row(Warehouse)) as cur:
        cur.execute(_SELECT_WAREHOUSE + " WHERE w.id = %s", (_id,))
        return cur.fetchone()


def _load_cities() -> dict[str, int]:
    """Возвращает отображение название города -> id для выбора при вводе."""
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("SELECT name, id FROM catalog.cities ORDER BY name")
        return dict(cur.fetchall())


def _prompt_city(cities: dict[str, int], default: str | None = None) -> int:
    """Интерактивный выбор города из таблицы catalog.cities (Tab)."""
    names = list(cities.keys())
    completer = WordCompleter(names, ignore_case=True, sentence=True)
    validator = ChoiceValidator(
        names,
        message="Город должен быть из списка. Используйте Tab для автодополнения.",
    )
    name = prompt(
        "Город: ",
        default=default or "",
        completer=completer,
        validator=validator,
    ).strip()
    return cities[name]


def _warehouse_count(conn: Connection) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM catalog.warehouses")
        return cur.fetchone()[0]  # type: ignore[index]


def _clear_central(conn: Connection) -> None:
    """Снимает флаг центрального со всех складов (перед назначением нового)."""
    conn.execute(
        "UPDATE catalog.warehouses SET is_central = false WHERE is_central = true"
    )


def _ask_is_central(default: bool) -> bool:
    answer = prompt(
        "Центральный склад? (y/n, д/н): ",
        default="y" if default else "n",
        validator=YesNoValidator(),
    )
    return YesNoValidator.is_yes(answer)


@command(
    "list warehouses",
    "список всех складов",
    CATEGORY_WAREHOUSES,
    list(ALL_ROLES),
)
def list_warehouses() -> None:
    conn = get_conn()
    table = Table(title="Склады", show_header=True, header_style="bold cyan")

    table.add_column("ID", style="dim", width=6, justify="right")
    table.add_column("Город", style="green", min_width=20)
    table.add_column("Адрес", style="yellow", min_width=30)
    table.add_column("Метка", style="magenta", min_width=15)
    table.add_column("Центральный", style="cyan", justify="center", min_width=11)

    with conn.cursor(row_factory=class_row(Warehouse)) as cur:
        cur.execute(_SELECT_WAREHOUSE + " ORDER BY w.id")
        warehouses: list[Warehouse] = cur.fetchall()

    for warehouse in warehouses:
        table.add_row(
            str(warehouse.id),
            warehouse.city,
            warehouse.address,
            warehouse.label or "",
            "да" if warehouse.is_central else "",
        )
    console.print(table)


@command(
    "show warehouse",
    "информация о складе",
    CATEGORY_WAREHOUSES,
    list(ALL_ROLES),
)
def show_warehouse(_id: str) -> None:
    warehouse = _find_warehouse(_id)
    if warehouse is None:
        render_error(f"Склад с ID {_id} не найден")
        return
    _render_warehouse(warehouse)


@command(
    "add warehouse",
    "добавить склад (интерактивно)",
    CATEGORY_WAREHOUSES,
    [ROLE_CATALOG_MANAGER],
)
def add_warehouse() -> None:
    conn = get_conn()
    cities = _load_cities()
    city_id = _prompt_city(cities)
    address = prompt("Адрес: ", validator=NonEmptyValidator()).strip()
    label = prompt("Метка (необязательно): ").strip() or None

    # первый склад всегда центральный
    if _warehouse_count(conn) == 0:
        is_central = True
        console.print("[dim]Это первый склад, он становится центральным.[/dim]")
    else:
        is_central = _ask_is_central(default=False)

    with conn.transaction():
        if is_central:
            _clear_central(conn)
        conn.execute(
            """INSERT INTO catalog.warehouses (city_id, address, label, is_central)
            VALUES (%s, %s, %s, %s)""",
            (city_id, address, label, is_central),
        )

    city = next(name for name, cid in cities.items() if cid == city_id)
    suffix = f" ({label})" if label else ""
    central = " [центральный]" if is_central else ""
    console.print(f"[green]Склад в городе {city}{suffix}{central} добавлен[/green]")


@command(
    "edit warehouse",
    "редактировать склад",
    CATEGORY_WAREHOUSES,
    [ROLE_CATALOG_MANAGER],
)
def edit_warehouse(_id: str) -> None:
    conn = get_conn()
    warehouse = _find_warehouse(_id)
    if warehouse is None:
        render_error(f"Склад с ID {_id} не найден")
        return

    cities = _load_cities()
    city_id = _prompt_city(cities, default=warehouse.city)
    address = prompt(
        "Адрес: ", default=warehouse.address, validator=NonEmptyValidator()
    ).strip()
    label = (
        prompt("Метка (необязательно): ", default=warehouse.label or "").strip() or None
    )
    # центральный склад один, снять флаг с него нельзя, поэтому и не спрашиваем
    if warehouse.is_central:
        is_central = True
    else:
        is_central = _ask_is_central(default=False)

    with conn.transaction():
        if is_central and not warehouse.is_central:
            _clear_central(conn)
        conn.execute(
            """UPDATE catalog.warehouses
            SET city_id = %s, address = %s, label = %s, is_central = %s
            WHERE id = %s""",
            (city_id, address, label, is_central, _id),
        )

    city = next(name for name, cid in cities.items() if cid == city_id)
    suffix = f" ({label})" if label else ""
    console.print(f"[green]Склад в городе {city}{suffix} обновлен[/green]")


@command(
    "delete warehouse",
    "удалить склад",
    CATEGORY_WAREHOUSES,
    [ROLE_CATALOG_MANAGER],
)
def delete_warehouse(_id: str) -> None:
    conn = get_conn()
    warehouse = _find_warehouse(_id)
    if warehouse is None:
        render_error(f"Склад с ID {_id} не найден")
        return

    # центральный склад нельзя удалить, пока есть другие
    if warehouse.is_central and _warehouse_count(conn) > 1:
        render_error(
            "Нельзя удалить центральный склад, пока есть другие склады. "
            "Сначала назначьте центральным другой склад (edit warehouse)."
        )
        return

    _render_warehouse(warehouse)

    answer = prompt("Вы уверены? (y/n, д/н): ", validator=YesNoValidator())
    if not YesNoValidator.is_yes(answer):
        return

    conn.execute("DELETE FROM catalog.warehouses WHERE id = %s", (_id,))
    suffix = f" ({warehouse.label})" if warehouse.label else ""
    console.print(f"[green]Склад в городе {warehouse.city}{suffix} удален[/green]")
