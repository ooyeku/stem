/* Linked list with reverse. Build with: cc main.c -o main && ./main */

#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
    int value;
    struct Node *next;
} Node;

static Node *push(Node *head, int value) {
    Node *node = malloc(sizeof(Node));
    if (!node) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    node->value = value;
    node->next = head;
    return node;
}

static Node *reverse(Node *head) {
    Node *prev = NULL;
    while (head) {
        Node *next = head->next;
        head->next = prev;
        prev = head;
        head = next;
    }
    return prev;
}

static void print_list(const Node *head) {
    for (const Node *n = head; n; n = n->next) {
        printf("%d%s", n->value, n->next ? " -> " : "\n");
    }
}

static void free_list(Node *head) {
    while (head) {
        Node *next = head->next;
        free(head);
        head = next;
    }
}

int main(void) {
    Node *list = NULL;
    for (int i = 1; i <= 5; i++) list = push(list, i);

    printf("original: ");
    print_list(list);

    list = reverse(list);
    printf("reversed: ");
    print_list(list);

    free_list(list);
    return 0;
}
