from dataclasses import dataclass

import psycopg
from prompt_toolkit import prompt
from psycopg.rows import class_row
from rich.panel import Panel
from rich.table import Table

from console import console, render_error
from db import get_conn
from validators import NonEmptyValidator, YesNoValidator
from auth import ALL_ROLES, ROLE_CATALOG_MANAGER
from commands import command, CATEGORY_CATEGORIES


@dataclass
class Category:
    id: int
    name: str


def _render_category(category: Category) -> None:
    table = Table(show_header=False, box=None, padding=(0, 2))

    table.add_column("Поле", style="bold cyan", width=15)
    table.add_column("Значение", style="white")

    table.add_row("ID", str(category.id))
    table.add_row("Название", category.name)

    panel = Panel(
        table,
        expand=False,
        title=f"[bold green]Категория #{category.id}[/bold green]",
        border_style="green",
    )

    console.print(panel)


def _find_category(_id: str) -> Category | None:
    conn = get_conn()
    with conn.cursor(row_factory=class_row(Category)) as cur:
        cur.execute("SELECT * FROM catalog.product_categories WHERE id = %s", (_id,))
        return cur.fetchone()


@command(
    "list product_categories",
    "список всех категорий",
    CATEGORY_CATEGORIES,
    list(ALL_ROLES),
)
def list_categories() -> None:
    conn = get_conn()
    table = Table(title="Категории товаров", show_header=True, header_style="bold cyan")

    table.add_column("ID", style="dim", width=6, justify="right")
    table.add_column("Название", style="green", min_width=20)

    with conn.cursor(row_factory=class_row(Category)) as cur:
        cur.execute("SELECT * FROM catalog.product_categories ORDER BY id")
        categories: list[Category] = cur.fetchall()

    for category in categories:
        table.add_row(str(category.id), category.name)
    console.print(table)


@command(
    "show product_category",
    "информация о категории",
    CATEGORY_CATEGORIES,
    list(ALL_ROLES),
)
def show_category(_id: str) -> None:
    category = _find_category(_id)
    if category is None:
        render_error(f"Категория с ID {_id} не найдена")
        return
    _render_category(category)


@command(
    "add product_category",
    "добавить категорию",
    CATEGORY_CATEGORIES,
    [ROLE_CATALOG_MANAGER],
)
def add_category() -> None:
    conn = get_conn()
    name = prompt("Название: ", validator=NonEmptyValidator()).strip()
    try:
        conn.execute(
            "INSERT INTO catalog.product_categories (name) VALUES (%s)", (name,)
        )
    except psycopg.errors.UniqueViolation:
        render_error(f"Категория {name} уже существует")
        return
    console.print(f"[green]Категория {name} добавлена[/green]")


@command(
    "edit product_category",
    "редактировать категорию",
    CATEGORY_CATEGORIES,
    [ROLE_CATALOG_MANAGER],
)
def edit_category(_id: str) -> None:
    conn = get_conn()
    category = _find_category(_id)
    if category is None:
        render_error(f"Категория с ID {_id} не найдена")
        return

    name = prompt(
        "Название: ", default=category.name, validator=NonEmptyValidator()
    ).strip()
    try:
        conn.execute(
            "UPDATE catalog.product_categories SET name = %s WHERE id = %s",
            (name, _id),
        )
    except psycopg.errors.UniqueViolation:
        render_error(f"Категория {name} уже существует")
        return
    console.print(f"[green]Категория {name} обновлена[/green]")


@command(
    "delete product_category",
    "удалить категорию",
    CATEGORY_CATEGORIES,
    [ROLE_CATALOG_MANAGER],
)
def delete_category(_id: str) -> None:
    conn = get_conn()
    category = _find_category(_id)
    if category is None:
        render_error(f"Категория с ID {_id} не найдена")
        return

    _render_category(category)

    answer = prompt("Вы уверены? (y/n, д/н): ", validator=YesNoValidator())
    if not YesNoValidator.is_yes(answer):
        return

    try:
        conn.execute("DELETE FROM catalog.product_categories WHERE id = %s", (_id,))
    except (psycopg.errors.ForeignKeyViolation, psycopg.errors.RestrictViolation):
        render_error(
            f"Нельзя удалить категорию {category.name}: "
            "к ней привязаны товары. Сначала измените их категорию."
        )
        return
    console.print(f"[green]Категория {category.name} удалена[/green]")
